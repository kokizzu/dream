(* This file is part of Dream, released under the MIT license. See LICENSE.md
   for details, or visit https://github.com/aantron/dream.

   Copyright 2021 Anton Bachin *)



module Log = Dream__server.Log
module Message = Dream_pure.Message



let log =
  Log.sub_log "dream.sql"

(* TODO Debug metadata for the pools. *)
let pool_field : (_, Caqti_error.t) Caqti_lwt_unix.Pool.t Message.field =
  Message.new_field ()

(* TODO This may not be necessary since Caqti 1.8.0. May require some messing
   around, "Enable foreign key constraint checks for SQLite3 starting at tweaks
   version 1.8." in CHANGES. *)
let foreign_keys_on =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->. Caqti_type.unit) "PRAGMA foreign_keys = ON"
  [@ocaml.warning "-3"]

let post_connect (module Db : Caqti_lwt.CONNECTION) =
  match Caqti_driver_info.dialect_tag Db.driver_info with
  | `Sqlite -> Db.exec foreign_keys_on ()
  | _ -> Lwt.return (Ok ())

let sql_pool ?size uri =
    let pool_cell = ref None in
    fun inner_handler request ->

  begin match !pool_cell with
  | Some pool ->
    Message.set_field request pool_field pool;
    inner_handler request
  | None ->
    (* The correctness of this code is subtle. There is no race condition with
       two requests attempting to create a pool only because none of the code
       between checking pool_cell and setting it calls into Lwt. *)
    let parsed_uri = Uri.of_string uri in
    if Uri.scheme parsed_uri = Some "sqlite" then
      log.warning (fun log -> log ~request
        "Dream.sql_pool: \
        'sqlite' is not a valid scheme; did you mean 'sqlite3'?");
    let pool =
      let pool_config = Caqti_pool_config.create ?max_size:size () in
      Caqti_lwt_unix.connect_pool ~pool_config ~post_connect parsed_uri in
    match pool with
    | Ok pool ->
      pool_cell := Some pool;
      Message.set_field request pool_field pool;
      inner_handler request
    | Error error ->
      (* Deliberately raise an exception so that it can be communicated to any
         debug handler. *)
      let message =
        Printf.sprintf "Dream.sql_pool: cannot create pool for '%s': %s"
         uri (Caqti_error.show error) in
      log.error (fun log -> log ~request "%s" message);
      failwith message
  end

(* In case a user calls Dream.sql within the callback of an outer call to
   Dream.sql, if the database driver does not support concurrent database
   connections, as with caqti-driver-sqlite3, the inner call to Dream.sql cannot
   make progress and request handling deadlocks. This can occur when using SQL
   sessions, a typical scenario. See
   https://github.com/aantron/dream/issues/332. *)
let acquired_sql_connection : bool Lwt.key =
  Lwt.new_key ()

let sql request callback =
  match Message.field request pool_field with
  | None ->
    let message = "Dream.sql: no pool; did you apply Dream.sql_pool?" in
    log.error (fun log -> log ~request "%s" message);
    failwith message
  | Some pool ->
    begin match Lwt.get acquired_sql_connection with
    | None | Some false -> ()
    | Some true ->
      let message =
        "Re-entrant call to Dream.sql, perhaps through " ^
        "Dream.set_session_field; could cause deadlock"
      in
      log.warning (fun log -> log ~request "%s" message)
    end;
    let%lwt result =
      pool |> Caqti_lwt_unix.Pool.use (fun db ->
        Lwt.with_value acquired_sql_connection (Some true) @@ fun () ->
        (* The special exception handling is a workaround for
           https://github.com/paurkedal/ocaml-caqti/issues/68. *)
        match%lwt callback db with
        | result -> Lwt.return (Ok result)
        | exception exn -> raise exn)
    in
    Caqti_lwt.or_fail result
