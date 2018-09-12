open Lwt.Infix
open Capnp_rpc_lwt

module Api = Irmin_api.MakeRPC(Capnp_rpc_lwt)
type t = [ `Irmin_b2b5cb4fd15c7d5a ] Capability.t

module type CLIENT = sig
  module Store: Irmin.S
  val get: t -> ?branch:Store.branch -> Store.key -> (Store.contents, [`Msg of string]) result Lwt.t
  val get_tree: t -> ?branch:Store.branch -> Store.key -> Store.tree Lwt.t
  val set: t -> ?branch:Store.branch -> ?author:string -> ?message:string -> Store.key -> Store.contents -> Store.Commit.hash Lwt.t
  val set_tree: t -> ?branch:Store.branch -> ?author:string -> ?message:string -> Store.key -> Store.tree -> Store.Commit.hash Lwt.t
  val remove: t -> ?branch:Store.branch -> ?author:string -> ?message:string -> Store.key -> Store.Commit.hash Lwt.t
  val clone: t -> ?branch:Store.branch -> string -> Store.Commit.hash Lwt.t
  val pull: t -> ?branch:Store.branch -> ?author:string -> ?message:string -> string -> Store.Commit.hash Lwt.t
  val push: t -> ?branch:Store.branch -> string -> unit Lwt.t
  val merge: t -> ?branch:Store.branch -> ?author:string -> ?message:string -> Store.branch -> (Store.Commit.hash, Irmin.Merge.conflict) result Lwt.t
  val commit_info: t -> Store.Commit.Hash.t -> Irmin.Info.t Lwt.t
  val snapshot: ?branch:Store.branch -> t -> (Store.Commit.Hash.t, [`Msg of string]) result Lwt.t
  val revert: t -> ?branch:Store.branch -> Store.Commit.Hash.t -> bool Lwt.t
  val branches: t -> Store.branch list Lwt.t
  val commit_history: t -> Store.Commit.Hash.t -> Store.Commit.Hash.t list Lwt.t
end

module type S = sig
  module Store: Irmin.S

  val local: Store.repo -> t

  module Client: CLIENT with module Store = Store
end

exception Error_message of string
let unwrap = function
  | Ok x -> x
  | Error (`Msg m) -> raise (Error_message m)

module Make(Store: Irmin.S)(Info: sig
  val info: ?author:string -> ('a, Format.formatter, unit, Irmin.Info.f) format4 -> 'a
end) = struct
  module Store = Store
  module Sync = Irmin.Sync(Store)

  (* Convert a Store.tree to capnproto Tree object *)
  let rec encode_tree tr key (tree: Store.tree): unit Lwt.t =
    let module Tree = Api.Builder.Irmin.Tree in
    let module Node = Api.Builder.Irmin.Node in
    let ks = Fmt.to_to_string Store.Key.pp key in
    ignore @@ Tree.key_set tr ks;
    Store.Tree.to_concrete tree >>= function
    | `Contents (contents, _) ->
        let _ = Tree.contents_set tr (Fmt.to_to_string Store.Contents.pp contents) in
        Lwt.return_unit
    | `Tree l ->
        Lwt_list.map_p (fun (step, tree) ->
          let node = Node.init_root () in
          let step_s = Fmt.to_to_string Store.Key.pp_step step in
          Node.step_set node step_s;
          let tt = Node.tree_init node in
          let tree = Store.Tree.of_concrete tree in
          encode_tree tt (Store.Key.rcons key step) tree >|= fun () -> node
        ) l
        >>= fun l ->
          let _ = Tree.node_set_list tr l in Lwt.return_unit

  let rec decode_tree tree: Store.Tree.concrete =
    let module Tree = Api.Reader.Irmin.Tree in
    let module Node = Api.Reader.Irmin.Node in
    match Tree.get tree with
    | Node l ->
        let l = Capnp.Array.to_list l in
        `Tree (List.map (fun node ->
          let step = Node.step_get node |> Store.Key.step_of_string |> unwrap in
          let tree = Node.tree_get node |> decode_tree in
          step, tree) l)
    | Contents c ->
        let c = Store.Contents.of_string c |> unwrap in
        `Contents (c, Store.Metadata.default)
    | Undefined _ -> `Tree []

  let encode_commit_info cm info =
    let module Info = Api.Builder.Irmin.Info in
    let i = Store.Commit.info cm in
    Info.author_set info (Irmin.Info.author i);
    Info.message_set info (Irmin.Info.message i);
    Info.date_set info (Irmin.Info.date i)

  let encode_commit commit cm =
    let module Commit = Api.Builder.Irmin.Commit in
    let module Info = Api.Builder.Irmin.Info in
    let info = Commit.info_init commit in
    Commit.hash_set commit (Fmt.to_to_string Store.Commit.Hash.pp (Store.Commit.hash cm));
    let tr = Commit.tree_init commit in
    Store.Commit.tree cm >>= fun tree ->
    encode_tree tr Store.Key.empty tree >|= fun () ->
    encode_commit_info cm info

  let local ctx =
    let module Ir = Api.Service.Irmin in
    Ir.local @@ object
      inherit Ir.service

      method get_impl req release_params =
        let open Ir.Get in
        let branch = Params.branch_get req |> Store.Branch.of_string |> unwrap in
        let key = Params.key_get req
          |> Store.Key.of_string
          |> unwrap
        in
        release_params ();
        Service.return_lwt (fun () ->
          let resp, results = Service.Response.create Results.init_pointer in
          Store.of_branch ctx branch >>= fun t ->
          Store.find t key >>= function
          | Some value ->
              Results.result_set results (Fmt.to_to_string Store.Contents.pp value);
              Lwt.return_ok resp
          | None ->
            let err = Capnp_rpc.Error.exn ~ty:`Failed "%s" "Not found" in
            Lwt.return_error err)

      method set_impl req release_params =
        let open Ir.Set in
        let branch = Params.branch_get req |> Store.Branch.of_string |> unwrap in
        let key = Params.key_get req |> Store.Key.of_string |> unwrap in
        let value = Params.value_get req in
        let message = if Params.has_message req then Params.message_get req else "set" in
        let author = if Params.has_author req then Params.author_get req else "irmin-rpc" in
        release_params ();
        Service.return_lwt (fun () ->
          let resp, results = Service.Response.create Results.init_pointer in
          Store.of_branch ctx branch >>= fun t ->
          (match Store.Contents.of_string value with
          | Ok value ->
            Store.set t key value ~info:(Info.info ~author "%s" message) >>= fun () ->
            Store.Head.get t >>= fun head ->
            let commit = Results.result_init results in
            encode_commit commit head
          | Error _ -> Lwt.return_unit) >>= fun _ ->
          Lwt.return_ok resp)

      method remove_impl req release_params =
        let open Ir.Remove in
        let branch = Params.branch_get req |> Store.Branch.of_string |> unwrap in
        let key = Params.key_get req |> Store.Key.of_string |> unwrap in
        let message = if Params.has_message req then Params.message_get req else "remove" in
        let author = if Params.has_author req then Params.author_get req else "irmin-rpc" in
        release_params ();
        Service.return_lwt (fun () ->
          let resp, results = Service.Response.create Results.init_pointer in
          Store.of_branch ctx branch >>= fun t ->
          Store.remove t key ~info:(Info.info ~author "%s" message) >>= fun () ->
          Store.Head.get t >>= fun head ->
          let commit = Results.result_init results in
          encode_commit commit head >>= fun () ->
          Lwt.return_ok resp)

      method get_tree_impl req release_params =
        let open Ir.GetTree in
        let module Tree = Api.Builder.Irmin.Tree in
        let module Node = Api.Builder.Irmin.Node in
        let branch = Params.branch_get req |> Store.Branch.of_string |> unwrap in
        let key = Params.key_get req |> Store.Key.of_string |> unwrap in
        release_params ();
        Service.return_lwt (fun () ->
          let resp, results = Service.Response.create Results.init_pointer in
          Store.of_branch ctx branch >>= fun t ->
          Store.get_tree t key >>= fun tree ->
          let tr = Results.result_init results in
          encode_tree tr key tree >>= fun () ->
          Lwt.return_ok resp)

      method set_tree_impl req release_params =
        let open Ir.SetTree in
        let module Tree = Api.Builder.Irmin.Tree in
        let module Node = Api.Builder.Irmin.Node in
        let branch = Params.branch_get req |> Store.Branch.of_string |> unwrap in
        let key = Params.key_get req |> Store.Key.of_string |> unwrap in
        let tree = Params.tree_get req in
        let message = if Params.has_message req then Params.message_get req else "remove" in
        let author = if Params.has_author req then Params.author_get req else "irmin-rpc" in
        release_params ();
        Service.return_lwt (fun () ->
          let resp, results = Service.Response.create Results.init_pointer in
          Store.of_branch ctx branch >>= fun t ->
          let tree = decode_tree tree |> Store.Tree.of_concrete in
          Store.set_tree t key tree ~info:(Info.info ~author "%s" message) >>= fun () ->
          Store.Head.get t >>= fun head ->
          let commit = Results.result_init results in
          encode_commit commit head >>= fun () ->
          Lwt.return_ok resp)

      method clone_impl req release_params =
        let open Ir.Clone in
        let remote = Params.remote_get req |> Irmin.remote_uri in
        let branch = Params.branch_get req |> Store.Branch.of_string |> unwrap in
        release_params ();
        Service.return_lwt (fun () ->
          let resp, results = Service.Response.create Results.init_pointer in
          Store.of_branch ctx branch >>= fun t ->
          Sync.fetch_exn t remote >>= fun head ->
          let commit = Results.result_init results in
          encode_commit commit head >>= fun () ->
          Lwt.return_ok resp
        )

      method push_impl req release_params =
        let open Ir.Push in
        let remote = Params.remote_get req |> Irmin.remote_uri in
        let branch = Params.branch_get req |> Store.Branch.of_string |> unwrap in
        release_params ();
        Service.return_lwt (fun () ->
          let resp, _result = Service.Response.create Results.init_pointer in
          Store.of_branch ctx branch >>= fun t ->
          Sync.push_exn t remote >>= fun () ->
          Lwt.return_ok resp)

      method pull_impl req release_params =
        let open Ir.Pull in
        let remote = Params.remote_get req |> Irmin.remote_uri in
        let branch = Params.branch_get req |> Store.Branch.of_string |> unwrap in
        let message = if Params.has_message req then Params.message_get req else "remove" in
        let author = if Params.has_author req then Params.author_get req else "irmin-rpc" in
        release_params ();
        let info = Info.info ~author "%s" message in
        Service.return_lwt (fun () ->
          let resp, results = Service.Response.create Results.init_pointer in
          Store.of_branch ctx branch >>= fun t ->
          Sync.pull_exn t remote (`Merge info) >>= fun () ->
          Store.Head.get t >>= fun head ->
          let commit = Results.result_init results in
          encode_commit commit head >>= fun () ->
          Lwt.return_ok resp
        )

      method merge_impl req release_params =
        let open Ir.Merge in
        let from_ = Params.branch_from_get req |> Store.Branch.of_string |> unwrap in
        let into_ = Params.branch_into_get req |> Store.Branch.of_string |> unwrap in
        let message = if Params.has_message req then Params.message_get req else "remove" in
        let author = if Params.has_author req then Params.author_get req else "irmin-rpc" in
        release_params ();
        let info = Info.info ~author "%s" message in
        Service.return_lwt (fun () ->
          let resp, results = Service.Response.create Results.init_pointer in
          Store.of_branch ctx into_ >>= fun t ->
          Store.merge_with_branch t from_  ~info >>= fun res ->
          match res with
          | Ok () ->
            Store.Head.get t >>= fun head ->
            let commit = Results.result_init results in
            encode_commit commit head >>= fun () ->
            Lwt.return_ok resp
          | Error e ->
              let msg = (Fmt.to_to_string (Irmin.Type.pp_json Irmin.Merge.conflict_t) e) in
              let err = Capnp_rpc.Error.exn ~ty:`Failed "%s" msg in
              Lwt.return_error err
        )

      method commit_info_impl req release_params =
        let open Ir.CommitInfo in
        let hash = Params.hash_get req in
        release_params ();
        Service.return_lwt (fun () ->
          match Store.Commit.Hash.of_string hash with
          | Ok hash ->
              let resp, results = Service.Response.create Results.init_pointer in
              (Store.Commit.of_hash ctx hash >>= function
              | Some c ->
                let info = Results.result_init results in
                encode_commit_info c info;
                Lwt.return_ok resp
              | None -> Lwt.return_ok resp)
          | Error (`Msg msg) ->
              let err = Capnp_rpc.Error.exn ~ty:`Failed "%s" msg in
              Lwt.return_error err
        )

      method snapshot_impl req release_params =
        let open Ir.Snapshot in
        let branch = Params.branch_get req |> Store.Branch.of_string |> unwrap in
        release_params ();
        Service.return_lwt (fun () ->
          Store.of_branch ctx branch >>= fun t ->
          Store.Head.get t >>= fun commit ->
          let resp, results = Service.Response.create Results.init_pointer in
          Results.result_set results (Store.Commit.hash commit |> Fmt.to_to_string Store.Commit.Hash.pp);
          Lwt.return_ok resp
        )

      method revert_impl req release_params =
        let open Ir.Revert in
        let branch = Params.branch_get req |> Store.Branch.of_string |> unwrap in
        let commit = Params.hash_get req |> Store.Commit.Hash.of_string |> unwrap in
        release_params ();
        Service.return_lwt (fun () ->
          let resp, results = Service.Response.create Results.init_pointer in
          Store.of_branch ctx branch >>= fun t ->
          (Store.Commit.of_hash ctx commit >>= function
            | Some commit ->
                Store.Head.set t commit >|= fun () ->
                Results.result_set results true
            | None -> Results.result_set results false; Lwt.return_unit) >>= fun () ->
          Lwt.return_ok resp
        )

       method branches_impl _req release_params =
         let open Ir.Branches in
         release_params ();
         Service.return_lwt (fun () ->
          let resp, results = Service.Response.create Results.init_pointer in
          Store.Branch.list ctx  >>= fun branches ->
          let l = List.map (fun x -> Fmt.to_to_string Store.Branch.pp x) branches in
          let _ = Results.result_set_list results l in
          Lwt.return_ok resp
        )

        method commit_history_impl req release_params =
          let open Ir.CommitHistory in
          let commit = Params.hash_get req |> Store.Commit.Hash.of_string |> unwrap in
          release_params ();
          Service.return_lwt (fun () ->
            let resp, results = Service.Response.create Results.init_pointer in
            (Store.Commit.of_hash ctx commit >>= function
              | Some commit ->
                  Store.Commit.parents commit >>= Lwt_list.map_p (fun commit ->
                    Fmt.to_to_string Store.Commit.Hash.pp (Store.Commit.hash commit)
                    |> Lwt.return
                  ) >|= fun l ->
                  ignore (Results.result_set_list results l)
              | None ->
                  ignore (Results.result_set_list results []);
                  Lwt.return_unit
            ) >>= fun () ->
            Lwt.return_ok resp
          )
    end

    module Client = struct
      module Store = Store
      module Ir = Api.Client.Irmin

      let branch_param branch_set p branch =
        match branch with
        | Some br ->
            let br = Fmt.to_to_string Store.Branch.pp br in
            branch_set p br
        | None -> branch_set p "master"

      let author_param author_set p author =
        match author with
        | Some author ->
            author_set p author
        | _ -> ()

      let message_param message_set p message =
        match message with
        | Some message ->
            message_set p message
        | _ -> ()

      let get t ?branch key =
        let open Ir.Get in
        let req, p = Capability.Request.create Params.init_pointer in
        branch_param Params.branch_set p branch;
        let key_s = Fmt.to_to_string Store.Key.pp key in
        Params.key_set p key_s |> ignore;
        Capability.call_for_value_exn t method_id req >|= fun res ->
        Store.Contents.of_string (Results.result_get res)

      let get_tree t ?branch key =
        let open Ir.GetTree in
        let req, p = Capability.Request.create Params.init_pointer in
        branch_param Params.branch_set p branch;
        let key_s = Fmt.to_to_string Store.Key.pp key in
        Params.key_set p key_s |> ignore;
        Capability.call_for_value_exn t method_id req >|= fun res ->
        Results.result_get res |> decode_tree |> Store.Tree.of_concrete

      let set t ?branch ?author ?message key value =
        let open Ir.Set in
        let req, p = Capability.Request.create Params.init_pointer in
        branch_param Params.branch_set p branch;
        author_param Params.author_set p author;
        message_param Params.message_set p message;
        let key_s = Fmt.to_to_string Store.Key.pp key in
        Params.key_set p key_s |> ignore;
        Params.value_set p (Fmt.to_to_string Store.Contents.pp value);
        Capability.call_for_value_exn t method_id req >|= fun res ->
        let commit = Results.result_get res in
        Api.Reader.Irmin.Commit.hash_get commit |> Store.Commit.Hash.of_string |> unwrap

      let set_tree t ?branch ?author ?message key tree =
        let open Ir.SetTree in
        let req, p = Capability.Request.create Params.init_pointer in
        branch_param Params.branch_set p branch;
        author_param Params.author_set p author;
        message_param Params.message_set p message;
        let key_s = Fmt.to_to_string Store.Key.pp key in
        Params.key_set p key_s |> ignore;
        let tr = Params.tree_init p in
        encode_tree tr key tree >>= fun () ->
        Capability.call_for_value_exn t method_id req >|= fun res ->
        let commit = Results.result_get res in
        Api.Reader.Irmin.Commit.hash_get commit |> Store.Commit.Hash.of_string |> unwrap

      let remove t ?branch ?author ?message key =
        let open Ir.Remove in
        let req, p = Capability.Request.create Params.init_pointer in
        branch_param Params.branch_set p branch;
        author_param Params.author_set p author;
        message_param Params.message_set p message;
        let key_s = Fmt.to_to_string Store.Key.pp key in
        Params.key_set p key_s |> ignore;
        Capability.call_for_value_exn t method_id req >|= fun res ->
        let commit = Results.result_get res in
        (Api.Reader.Irmin.Commit.hash_get commit |> Store.Commit.Hash.of_string |> unwrap)

      let clone t ?branch remote =
        let open Ir.Clone in
        let req, p = Capability.Request.create Params.init_pointer in
        branch_param Params.branch_set p branch;
        Params.remote_set p remote;
        Capability.call_for_value_exn t method_id req >|= fun res ->
        let commit = Results.result_get res in
        (Api.Reader.Irmin.Commit.hash_get commit |> Store.Commit.Hash.of_string |> unwrap)

      let pull t ?branch ?author ?message remote =
        let open Ir.Pull in
        let req, p = Capability.Request.create Params.init_pointer in
        branch_param Params.branch_set p branch;
        author_param Params.author_set p author;
        message_param Params.message_set p message;
        Params.remote_set p remote;
        Capability.call_for_value_exn t method_id req >|= fun res ->
        let commit = Results.result_get res in
        (Api.Reader.Irmin.Commit.hash_get commit |> Store.Commit.Hash.of_string |> unwrap)

      let push t ?branch  remote =
        let open Ir.Push in
         let req, p = Capability.Request.create Params.init_pointer in
        branch_param Params.branch_set p branch;
        Params.remote_set p remote;
        Capability.call_for_unit_exn t method_id req

      let merge t ?branch ?author ?message from_ =
        let open Ir.Merge in
        let req, p = Capability.Request.create Params.init_pointer in
        branch_param Params.branch_into_set p branch;
        let from_ = Fmt.to_to_string Store.Branch.pp from_ in
        Params.branch_from_set p from_;
        author_param Params.author_set p author;
        message_param Params.message_set p message;
        Capability.call_for_value t method_id req >|= fun res ->
        match res with
        | Ok res ->
            let commit = Results.result_get res in
            Ok (Api.Reader.Irmin.Commit.hash_get commit |> Store.Commit.Hash.of_string |> unwrap)
        | Error err ->
            let err = Fmt.to_to_string Capnp_rpc.Error.pp err in
            let decoder = Jsonm.decoder (`String err) in
            Error (Irmin.Type.decode_json Irmin.Merge.conflict_t decoder |> unwrap)

      let commit_info t hash =
        let open Ir.CommitInfo in
        let req, p = Capability.Request.create Params.init_pointer in
        Params.hash_set p (Fmt.to_to_string Store.Commit.Hash.pp hash);
        Capability.call_for_value_exn t method_id req >|= fun res ->
        let info = Results.result_get res in
        let module Info = Api.Reader.Irmin.Info in
        let author = Info.author_get info in
        let date = Info.date_get info in
        let message = Info.message_get info in
        Irmin.Info.v ~date ~author message

      let snapshot ?branch t =
        let open Ir.Snapshot in
        let req, p = Capability.Request.create Params.init_pointer in
        branch_param Params.branch_set p branch;
        Capability.call_for_value_exn t method_id req >|= fun res ->
        let commit = Results.result_get res in
        Store.Commit.Hash.of_string commit

      let revert t ?branch hash =
        let open Ir.Revert in
        let req, p = Capability.Request.create Params.init_pointer in
        branch_param Params.branch_set p branch;
        Params.hash_set p (Fmt.to_to_string Store.Commit.Hash.pp hash);
        Capability.call_for_value_exn t method_id req >|= fun res ->
        Results.result_get res

      let branches t =
        let open Ir.Branches in
        let req, _ = Capability.Request.create Params.init_pointer in
        Capability.call_for_value_exn t method_id req >>= fun res ->
        let l = Results.result_get_list res in
        Lwt_list.filter_map_s (fun x ->
          match Store.Branch.of_string x with
          | Ok b -> Lwt.return_some b
          | Error _ -> Lwt.return_none) l

      let commit_history t hash =
        let open Ir.CommitHistory in
        let req, p = Capability.Request.create Params.init_pointer in
        Params.hash_set p ( Fmt.to_to_string Store.Commit.Hash.pp hash);
        Capability.call_for_value_exn t method_id req >>= fun res ->
        let l = Results.result_get_list res in
        Lwt_list.filter_map_s (fun x ->
          match Store.Commit.Hash.of_string x with
          | Ok b -> Lwt.return_some b
          | Error _ -> Lwt.return_none) l
    end
end

