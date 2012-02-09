open Lwt
open Arakoon_remote_client
open Arakoon_client

let make_address ip port =
  let ha = Unix.inet_addr_of_string ip in
  Unix.ADDR_INET (ha,port)

let with_client (ip,port) f =
  let sa = make_address ip port in
  let do_it connection = 
    let rc = new remote_client
      connection in 
    let client = (rc:> client) in
    f client
  in
  Lwt_io.with_connection sa do_it

let find_master cfgs =
  let rec loop = function
    | [] -> Lwt.fail (Failure "too many nodes down")
    | cfg :: rest ->
      begin
	let _,(ip, port) = cfg in
	let sa = make_address ip port in
	Lwt.catch
	  (fun () ->
	    Lwt_io.with_connection sa
	      (fun connection ->
		let client = new Arakoon_remote_client.remote_client connection in
		client # who_master ())
	    >>= function
	      | None -> Lwt.fail (Failure "No Master")
	      | Some m -> Lwt.return m)
	  (function 
	    | Unix.Unix_error(Unix.ECONNREFUSED,_,_ ) -> loop rest
	    | exn -> Lwt.fail exn
	  )
      end
  in loop cfgs


let with_master_client cfgs f =
  find_master cfgs >>= fun master_name ->
  let master_cfg = List.assoc master_name cfgs in
  with_client master_cfg f


let demo client =
  client # set "foo" "bar" >>= fun () ->
  client # get "foo" >>= fun v ->
  Lwt_io.printlf "foo=%s" v >>= fun () ->
  client # delete "foo" >>= fun () ->
  client # exists "foo" >>= fun e ->
  Lwt_io.printlf "have foo? %b" e

let _ = 
  let cfgs = [
    ("arakoon_0",("127.0.0.1",4000));
    ("arakoon_1",("127.0.0.1",4001));
    ("arakoon_2",("127.0.0.1",4002))]
  in
  Lwt_main.run (with_master_client cfgs demo)