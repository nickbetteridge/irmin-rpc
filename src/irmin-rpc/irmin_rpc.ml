open Lwt.Infix
open Capnp_rpc_lwt

module Api = Irmin_api.MakeRPC(Capnp_rpc_lwt)
type t = [ `Irmin_b2b5cb4fd15c7d5a ] Capability.t

module type S = sig
  module Store: Irmin.KV

  val local: Store.repo -> t

  module Client: sig
    val get: t -> Store.key -> (Store.contents, [`Msg of string]) result Lwt.t
    val set: t -> Store.key -> Store.contents -> bool Lwt.t
    val remove: t -> Store.key -> unit Lwt.t
  end
end

module Make(Store: Irmin.KV)(Info: sig
  val info: ?author:string -> ('a, Format.formatter, unit, Irmin.Info.f) format4 -> 'a
end) = struct
  module Store = Store

  let local ctx =
    let module Ir = Api.Service.Irmin in

    Ir.local @@ object
      inherit Ir.service

      method get_impl req release_params =
        let open Ir.Get in
        let branch = Params.branch_get req in
        let branch = Api.Reader.Irmin.Branch.name_get branch in
        let branch = Store.Branch.of_string branch in
        let key = Params.key_get_list req |> Store.Key.v in
        release_params ();
        Service.return_lwt (fun () ->
          let resp, results = Service.Response.create Results.init_pointer in
          (match branch with
          | Ok branch ->
            Store.of_branch ctx branch >>= fun t ->
            Store.find t key >|= fun value ->
            begin
              match value with
              | Some value ->
                Results.result_set results (Fmt.to_to_string Store.Contents.pp value)
              | None -> ()
            end
          | Error _ -> Lwt.return_unit) >>= fun () ->
          Lwt.return_ok resp)

      method set_impl req release_params =
        let open Ir.Set in
        let branch = Params.branch_get req in
        let branch = Api.Reader.Irmin.Branch.name_get branch in
        let key = Params.key_get_list req in
        let value = Params.value_get req in
        release_params ();
        Service.return_lwt (fun () ->
          let resp, results = Service.Response.create Results.init_pointer in
          Store.of_branch ctx branch >>= fun t ->
          (match Store.Contents.of_string value with
          | Ok value ->
            Lwt.catch (fun () ->
              Store.set t key value ~info:(Info.info "set") >>= fun () -> Lwt.return_true)
            (fun _ -> Lwt.return_false)
          | Error _ -> Lwt.return_false) >>= fun x ->
          Results.result_set results x;
          Lwt.return_ok resp)

      method remove_impl req release_params =
        let open Ir.Remove in
        let branch = Params.branch_get req in
        let branch = Api.Reader.Irmin.Branch.name_get branch in
        let key = Params.key_get_list req in
        release_params ();
        Service.return_lwt (fun () ->
          let resp, _results = Service.Response.create Results.init_pointer in
          Store.of_branch ctx branch >>= fun t ->
          Store.remove t key ~info:(Info.info "set") >>= fun () ->
          Lwt.return_ok resp)

      method master_impl _req release_params =
        let open Ir.Master in
        let module Branch = Api.Builder.Irmin.Branch in
        let module Commit = Api.Builder.Irmin.Commit in
        let module Info = Api.Builder.Irmin.Info in
        release_params ();
        Service.return_lwt (fun () ->
          let resp, results = Service.Response.create Results.init_pointer in
          let br = Results.result_init results in
          let commit = Branch.head_init br in
          let info = Commit.info_init commit in
          Store.master ctx >>= fun t ->
          Store.Head.find t >>= function
          | Some head ->
            Branch.name_set br "master";
            Commit.hash_set commit (Fmt.to_to_string Store.Commit.Hash.pp (Store.Commit.hash head));
            let i = Store.Commit.info head in
            Info.author_set info (Irmin.Info.author i);
            Info.message_set info (Irmin.Info.message i);
            Info.date_set info (Irmin.Info.date i);
            Lwt.return_ok resp
          | None -> Lwt.return_ok resp)

      method get_branch_impl req release_params =
        let open Ir.GetBranch in
        let module Branch = Api.Builder.Irmin.Branch in
        let module Commit = Api.Builder.Irmin.Commit in
        let module Info = Api.Builder.Irmin.Info in
        let name = Params.name_get req in
        release_params ();
        Service.return_lwt (fun () ->
          let resp, results = Service.Response.create Results.init_pointer in
          let br = Results.result_init results in
          let commit = Branch.head_init br in
          let info = Commit.info_init commit in
          Store.of_branch ctx name >>= fun t ->
          Store.Head.find t >>= function
          | Some head ->
            Branch.name_set br name;
            Commit.hash_set commit (Fmt.to_to_string Store.Commit.Hash.pp (Store.Commit.hash head));
            let i = Store.Commit.info head in
            Info.author_set info (Irmin.Info.author i);
            Info.message_set info (Irmin.Info.message i);
            Info.date_set info (Irmin.Info.date i);
            Lwt.return_ok resp
          | None -> Lwt.return_ok resp)


      method get_tree_impl =
        failwith "not implelemted"

    end

    module Client = struct
      module Ir = Api.Client.Irmin

      let get t key =
        let open Ir.Get in
        let req, p = Capability.Request.create Params.init_pointer in
        Params.key_set_list p key |> ignore;
        Capability.call_for_value_exn t method_id req >|= fun res ->
        Store.Contents.of_string (Results.result_get res)

      let set t key value =
        let open Ir.Set in
        let req, p = Capability.Request.create Params.init_pointer in
        Params.key_set_list p key |> ignore;
        Params.value_set p (Fmt.to_to_string Store.Contents.pp value);
        Capability.call_for_value_exn t method_id req >|= Results.result_get

      let remove t key: unit Lwt.t =
        let open Ir.Remove in
        let req, p = Capability.Request.create Params.init_pointer in
        Params.key_set_list p key |> ignore;
        Capability.call_for_value_exn t method_id req >>= fun _ -> Lwt.return_unit
    end
end

