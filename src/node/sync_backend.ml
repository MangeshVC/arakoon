(*
This file is part of Arakoon, a distributed key-value store. Copyright
(C) 2010 Incubaid BVBA

Licensees holding a valid Incubaid license may use this file in
accordance with Incubaid's Arakoon commercial license agreement. For
more information on how to enter into this agreement, please contact
Incubaid (contact details can be found on www.arakoon.org/licensing).

Alternatively, this file may be redistributed and/or modified under
the terms of the GNU Affero General Public License version 3, as
published by the Free Software Foundation. Under this license, this
file is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
FITNESS FOR A PARTICULAR PURPOSE.

See the GNU Affero General Public License for more details.
You should have received a copy of the
GNU Affero General Public License along with this program (file "COPYING").
If not, see <http://www.gnu.org/licenses/>.
*)

open Backend
open Statistics
open Client_cfg
open Node_cfg
open Lwt
open Log_extra
open Update
open Interval
open Mp_msg
open Common
open Store
open Master_type
open Tlogcommon

let _s_ = string_option2s

let ncfg_prefix_b4 = "nursery.cfg."
let ncfg_prefix_2far = "nursery.cfg/"
let ncfg_prefix_b4_o = Some ncfg_prefix_b4
let ncfg_prefix_2far_o = Some ncfg_prefix_2far

exception Forced_stop

let no_stats _ = ()

let make_went_well (stats_cb:Store.update_result -> unit) awake sleeper =
  fun b ->
    begin
      Lwt.catch
	( fun () ->Lwt.return (Lwt.wakeup awake b))
	( fun e ->
	  match e with
	    | Invalid_argument s ->
	      let t = state sleeper in
	      begin
		match t with
		  | Fail ex ->
		    begin
		      Lwt_log.error
			"Lwt.wakeup error: Sleeper already failed before. Re-raising"
		      >>= fun () ->
		      Lwt.fail ex
		    end
		  | Return v ->
		    Lwt_log.error "Lwt.wakeup error: Sleeper already returned"
		  | Sleep ->
		    Lwt.fail (Failure "Lwt.wakeup error: Sleeper is still sleeping however")
	      end
	    | _ -> Lwt.fail e
	) >>= fun () ->
      stats_cb b;
      Lwt.return ()
    end

let _mute_so _ = ()

let _update_rendezvous self ~so_post update update_stats push =
  self # _write_allowed () >>= fun () ->
  let sleep, awake = Lwt.wait () in
  let went_well = make_went_well update_stats awake sleep in
  push (update, went_well) >>= fun () ->
  let t0 = Unix.gettimeofday() in
  sleep >>= fun r ->
  let t1 = Unix.gettimeofday() in
  let t = (t1 -. t0) in
  let f =
    if t > 1.0
    then Lwt_log.info_f
    else Lwt_log.debug_f
  in
  f "rendezvous (%s) took %f" (Update.update2s update) t >>= fun () ->
  match r with
    | Store.Stop -> Lwt.fail Forced_stop
    | Store.Update_fail (rc,str) -> Lwt.fail (XException(rc,str))
  | Store.Ok so -> Lwt.return (so_post so)


class sync_backend cfg 
  (push_update:Update.t * (Store.update_result -> unit Lwt.t) -> unit Lwt.t) 
  (push_node_msg:Multi_paxos.paxos_event -> unit Lwt.t)
  (store:Store.store)
  (store_methods:
     (?read_only:bool -> string -> Store.store Lwt.t) *
     (string -> string -> bool -> unit Lwt.t) * string )
  (tlog_collection:Tlogcollection.tlog_collection)
  (lease_expiration:int)
  ~quorum_function n_nodes
  ~expect_reachable
  ~test
  ~(read_only:bool)
  ~max_value_size
  =
  let my_name =  Node_cfg.node_name cfg in
  let locked_tlogs = Hashtbl.create 8 in
  let blockers_cond = Lwt_condition.create() in
  let collapsing_lock = Lwt_mutex.create() in
  let assert_value_size value =
    let length = String.length value in
    if length >= max_value_size then
      raise (Arakoon_exc.Exception (Arakoon_exc.E_UNKNOWN_FAILURE,
				    "value too large"))
  in
object(self: #backend)
  val instantiation_time = Int64.of_float (Unix.time())
  val witnessed = Hashtbl.create 10
  val _stats = Statistics.create ()
  val mutable client_cfgs = None




  method exists ~allow_dirty key =
    log_o self "exists %s" key >>= fun () ->
    self # _read_allowed allow_dirty >>= fun () ->
    store # exists key

  method get ~allow_dirty key =
    let start = Unix.gettimeofday () in
    log_o self "get ~allow_dirty:%b %s" allow_dirty key >>= fun () ->
    self # _read_allowed allow_dirty >>= fun () ->
    self # _check_interval [key] >>= fun () ->
    Lwt.catch
      (fun () ->
	store # get key >>= fun v ->
	Statistics.new_get _stats key v start;
	Lwt.return v)
      (fun exc ->
	match exc with
	  | Not_found ->
	    Lwt.fail (Common.XException (Arakoon_exc.E_NOT_FOUND, key))
	  | Store.CorruptStore ->
	    begin
	      Lwt_log.fatal "CORRUPT_STORE" >>= fun () ->
	      Lwt.fail Server.FOOBAR
	    end
	  | ext -> Lwt.fail ext)

  method get_interval () =
    self # _read_allowed false >>= fun () ->
    store # get_interval ()


  method private block_collapser (i: Sn.t) =
    let tlog_file_n = tlog_collection # get_tlog_from_i i  in
    Hashtbl.add locked_tlogs tlog_file_n "locked"

  method private unblock_collapser i =
    let tlog_file_n = tlog_collection # get_tlog_from_i i in
    Hashtbl.remove locked_tlogs tlog_file_n;
    Lwt_condition.signal blockers_cond ()

  method private wait_for_tlog_release tlog_file_n =
    let blocking_requests = [] in
    let maybe_add_blocker tlog_num s blockers =
      if tlog_file_n >= tlog_num
      then
        tlog_num :: blockers
      else
        blockers
    in
    let blockers = Hashtbl.fold  maybe_add_blocker locked_tlogs blocking_requests in
    if List.length blockers > 0 then
      Lwt_condition.wait blockers_cond >>= fun () ->
      self # wait_for_tlog_release tlog_file_n
    else
      Lwt.return ()

  method range ~allow_dirty (first:string option) finc (last:string option) linc max =
    let start = Unix.gettimeofday() in
    log_o self "range %s %b %s %b %i" (_s_ first) finc (_s_ last) linc max >>= fun () ->
    self # _read_allowed allow_dirty >>= fun () ->
    self # _check_interval_range first last >>= fun () ->
    store # range first finc last linc max >>= fun keys ->
    let n_keys = List.length keys in
    Statistics.new_range _stats start n_keys;
    Lwt.return keys

  method last_entries (start_i:Sn.t) (oc:Lwt_io.output_channel) =

    Lwt.finalize(
      fun () ->
        begin
          self # block_collapser start_i ;
          self # _last_entries start_i oc
        end
    ) 
      (fun () -> Lwt.return ( self # unblock_collapser start_i )
    )

  method range_entries ~allow_dirty
    (first:string option) finc (last:string option) linc max =
    log_o self "range_entries %s %b %s %b %i" (_s_ first) finc (_s_ last) linc max >>= fun () ->
    self # _read_allowed allow_dirty >>= fun () ->
    self # _check_interval_range first last >>= fun () ->
    store # range_entries first finc last linc max 

  method rev_range_entries ~allow_dirty
    (first:string option) finc (last:string option) linc max =
    log_o self "rev_range_entries %s %b %s %b %i" (_s_ first) finc (_s_ last) linc max >>= fun () ->
    self # _read_allowed allow_dirty >>= fun () ->
    self # _check_interval_range last first >>= fun () ->
    store # rev_range_entries first finc last linc max

  method prefix_keys ~allow_dirty (prefix:string) (max:int) =
    let start = Unix.gettimeofday() in
    log_o self "prefix_keys %s %d" prefix max >>= fun () ->
    self # _read_allowed allow_dirty >>= fun () ->
    self # _check_interval [prefix]  >>= fun () ->
    store # prefix_keys prefix max   >>= fun key_list ->
    let n_keys = List.length key_list in
    Lwt_log.debug_f "prefix_keys found %d matching keys" n_keys >>= fun () ->
    Statistics.new_prefix_keys _stats start n_keys;
    Lwt.return key_list

  method set key value =
    let start = Unix.gettimeofday () in
    log_o self "set %S" key >>= fun () ->
    self # _check_interval [key] >>= fun () ->
    let () = assert_value_size value in
    let update = Update.Set(key,value) in
    let update_sets (update_result:Store.update_result) = Statistics.new_set _stats key value start in
    _update_rendezvous self update update_sets push_update ~so_post:_mute_so



  method confirm key value =
    log_o self "confirm %S" key >>= fun () ->
    let () = assert_value_size value in
    self # exists ~allow_dirty:false key >>= function
      | true ->
	    begin
	      store # get key >>= fun old_value ->
	      if old_value = value
	      then Lwt.return ()
	      else self # set key value
	    end
      | false -> self # set key value

  method set_routing r =
    log_o self "set_routing" >>= fun () ->
    let update = Update.SetRouting r in
    _update_rendezvous self update no_stats push_update ~so_post:_mute_so

  method set_routing_delta left sep right =
    log_o self "set_routing_delta" >>= fun () ->
    let update = Update.SetRoutingDelta (left, sep, right) in
    _update_rendezvous self update no_stats push_update ~so_post:_mute_so

  method set_interval iv =
    log_o self "set_interval %s" (Interval.to_string iv)>>= fun () ->
    let update = Update.SetInterval iv in
    _update_rendezvous self update no_stats push_update ~so_post:_mute_so

  method user_function name po =
    log_o self "user_function %s" name >>= fun () ->
    let update = Update.UserFunction(name,po) in
    let so_post so = so in
    _update_rendezvous self update no_stats push_update ~so_post

  method aSSert ~allow_dirty (key:string) (vo:string option) =
    log_o self "aSSert %S ..." key >>= fun () ->
    let update = Update.Assert(key,vo) in
    _update_rendezvous self update no_stats push_update ~so_post:_mute_so

 method aSSert_exists ~allow_dirty (key:string)=
    log_o self "aSSert %S ..." key >>= fun () ->
    let update = Update.Assert_exists(key) in
    _update_rendezvous self update no_stats push_update ~so_post:_mute_so

  method test_and_set key expected (wanted:string option) =
    let start = Unix.gettimeofday() in
    log_o self "test_and_set %s %s %s" key
      (string_option2s expected)
      (string_option2s wanted)
    >>= fun () ->
    let () = match wanted with
      | None -> ()
      | Some w -> assert_value_size w
    in
    let update = Update.TestAndSet(key, expected, wanted) in
    let update_stats ur = Statistics.new_testandset _stats start in
    let so_post so = so in
    _update_rendezvous self update update_stats push_update ~so_post

  method delete_prefix prefix = 
    let start = Unix.gettimeofday () in
    log_o self "delete_prefix %S" prefix >>= fun () ->
    (* do we need to test the prefix on the interval ? *)
    let update = Update.DeletePrefix prefix in
    let update_stats ur = 
      let n_keys = 
        match ur with 
          | Ok so -> (match so with | None -> 0 | Some ns -> let n,_ = Llio.int_from ns 0 in n)
          | _ -> failwith  "how did I get here?" (* exception would be thrown BEFORE we reach this *)
      in
      Statistics.new_delete_prefix _stats start n_keys
    in
    let so_post = function
      | None -> 0
      | Some s -> let r', _ = Llio.int_from s 0 in
                  r' 
    in
    _update_rendezvous self update update_stats push_update ~so_post


  method delete key = log_o self "delete %S" key >>= fun () ->
    let start = Unix.gettimeofday () in
    let update = Update.Delete key in
    let update_stats ur = Statistics.new_delete _stats start in
    _update_rendezvous self update update_stats push_update ~so_post:_mute_so

  method hello (client_id:string) (cluster_id:string) =
    log_o self "hello %S %S" client_id cluster_id >>= fun () ->
    let msg = Printf.sprintf "Arakoon %i.%i.%i" Version.major Version.minor Version.patch in
    Lwt.return (0l, msg)

  method private _last_entries (start_i:Sn.t) (oc:Lwt_io.output_channel) =
    log_o self "last_entries %s" (Sn.string_of start_i) >>= fun () ->
    let consensus_i = store # consensus_i () in
    begin
      match consensus_i with
	| None -> Lwt.return ()
	| Some ci ->
	  begin
	    tlog_collection # get_infimum_i () >>= fun inf_i ->
	    let too_far_i = Sn.succ ci in
	    log_o self
	      "inf_i:%s too_far_i:%s" (Sn.string_of inf_i)
	      (Sn.string_of too_far_i)


	    >>= fun () ->
	    begin
	      if start_i < inf_i
	      then
		begin
		  Llio.output_int oc 2 >>= fun () ->
		  tlog_collection # dump_head oc
		end
	      else
		Lwt.return start_i
	    end
	    >>= fun start_i2->
	    let step = Sn.of_int (!Tlogcommon.tlogEntriesPerFile) in
	    let rec loop_parts (start_i2:Sn.t) =
	      if Sn.rem start_i2 step = Sn.start &&
		 Sn.add start_i2 step < too_far_i
	      then
		begin
		  Lwt_log.debug_f "start_i2=%Li < %Li" start_i2 too_far_i
		  >>= fun () ->
		  Llio.output_int oc 3 >>= fun () ->
		  tlog_collection # dump_tlog_file start_i2 oc
		  >>= fun start_i2' ->
		  loop_parts start_i2'
		end
	      else
		Lwt.return start_i2
	    in
	    loop_parts start_i2
	    >>= fun start_i3 ->
	    Llio.output_int oc 1 >>= fun () ->
	    let f entry = 
          let i = Entry.i_of entry
          and v = Entry.v_of entry
          in
          Tlogcommon.write_entry oc i v in
	    tlog_collection # iterate start_i3 too_far_i f >>= fun () ->
	    Sn.output_sn oc (-1L)
	  end
    end
    >>= fun () ->
    log_o self "done with_last_entries"


  method sequence ~sync (updates:Update.t list) =
    let start = Unix.gettimeofday() in
    log_o self "sequence ~sync:%b" sync >>= fun () ->
    let update = if sync 
      then Update.SyncedSequence updates 
      else Update.Sequence updates
    in
    let update_stats ur = Statistics.new_sequence _stats start in
    let so_post _ = () in
    _update_rendezvous self update update_stats push_update ~so_post

  method multi_get ~allow_dirty (keys:string list) =
    let start = Unix.gettimeofday() in
    log_o self "multi_get" >>= fun () ->
    self # _read_allowed allow_dirty >>= fun () ->
    store # multi_get keys >>= fun values ->
    Statistics.new_multiget _stats start;
    Lwt.return values

  method to_string () = "sync_backend(" ^ (Node_cfg.node_name cfg) ^")"

  method private _who_master () =
    store # who_master ()

  method who_master () =
    let mo = self # _who_master () in
    let result,argumentation =
      match mo with
	| None -> None,"young cluster"
	| Some (m,ls) ->
	  match Node_cfg.get_master cfg with
	    | Elected | Preferred _ ->
	      begin
	      if (m = my_name ) && (ls < instantiation_time)
	      then None, (Printf.sprintf "%Li considered invalid lease from previous incarnation" ls)
	      else
		let now = Int64.of_float (Unix.time()) in
		let diff = Int64.sub now ls in
		if diff < Int64.of_int lease_expiration then
		  (Some m,"inside lease")
		else (None,Printf.sprintf "(%Li < (%Li = now) lease expired" ls now)
	      end
	    | Forced x -> Some x,"forced master"
	    | ReadOnly -> Some my_name, "readonly"

    in
    Lwt.return result

  method private _not_if_master() =
    self # who_master () >>= function
      | None ->
        Lwt.return ()
      | Some m ->
        if m = my_name
        then
          let msg = "Operation cannot be performed on master node" in
          Lwt.fail (XException(Arakoon_exc.E_UNKNOWN_FAILURE, msg))
        else
          Lwt.return ()

  method (* private *) _write_allowed () =
    if read_only
    then Lwt.fail (XException(Arakoon_exc.E_READ_ONLY, my_name))
    else
      begin
	    self # who_master () >>= function
	    | None ->
	      Lwt.fail (XException(Arakoon_exc.E_NOT_MASTER, "None"))
	    | Some m ->
	      if m <> my_name
	      then Lwt.fail (XException(Arakoon_exc.E_NOT_MASTER, m))
	      else Lwt.return ()
      end

  method private _read_allowed (allow_dirty:bool) =
    if allow_dirty or read_only
    then Lwt.return ()
    else self # _write_allowed ()

  method private _check_interval keys =
    store # get_interval () >>= fun iv ->
    let rec loop = function
      | [] -> Lwt.return ()
     (* | [k] ->
	if Interval.is_ok iv k then Lwt.return ()
	else Lwt.fail (XException(Arakoon_ex.E_OUTSIDE_INTERVAL, k)) *)
      | k :: keys ->
	if Interval.is_ok iv k
	then loop keys
	else Lwt.fail (XException(Arakoon_exc.E_OUTSIDE_INTERVAL, k))
    in
    loop keys

  method private _check_interval_range first last =
    store # get_interval () >>= fun iv ->
    let check_option = function
      | None -> Lwt.return ()
      | Some k ->
	if Interval.is_ok iv k
	then Lwt.return ()
	else Lwt.fail (XException(Arakoon_exc.E_OUTSIDE_INTERVAL, k))
    in
    check_option first >>= fun () ->
    check_option last

  method witness name i =
    Statistics.witness _stats name i;    
    let cio = store # consensus_i () in
    begin
      match cio with
	    | None -> ()
	    | Some ci -> Statistics.witness _stats my_name  ci
    end;
    ()
      
  method last_witnessed name = Statistics.last_witnessed _stats name

  method expect_progress_possible () =
    match store # consensus_i () with
      | None -> Lwt.return false
      | Some i ->
	let q = quorum_function n_nodes in
	let count,s = Hashtbl.fold
	  (fun name ci (count,s) ->
	    let s' = s ^ Printf.sprintf " (%s,%s) " name (Sn.string_of ci) in
	    if (expect_reachable ~target:name) &&
	      (ci = i || (Sn.pred ci) = i )
	    then  count+1,s'
	    else  count,s')
	  ( Statistics.get_witnessed _stats ) (1,"") in
	let v = count >= q in
	Lwt_log.debug_f "count:%i,q=%i i=%s detail:%s" count q (Sn.string_of i) s
	>>= fun () ->
	Lwt.return v

  method get_statistics () = _stats
  method clear_most_statistics () = Statistics.clear_most _stats
  method check ~cluster_id =
    let r = test ~cluster_id in
    Lwt.return r

  method collapse n cb' cb =
    begin
      if n < 1 then
        let rc = Arakoon_exc.E_UNKNOWN_FAILURE
        and msg = Printf.sprintf "%i is not acceptable" n
        in
        Lwt.fail (XException(rc,msg))
      else
        Lwt_log.debug_f "collapsing_lock locked: %s"
          (string_of_bool (Lwt_mutex.is_locked collapsing_lock)) >>= fun () ->
        if Lwt_mutex.is_locked collapsing_lock then
	        let rc = Arakoon_exc.E_UNKNOWN_FAILURE
	        and msg = "Collapsing already in progress"
          in
          Lwt.fail (XException(rc,msg))
        else
          Lwt.return ()
    end >>= fun () ->
    Lwt_mutex.with_lock collapsing_lock (fun () ->
      let new_cb tlog_num =
        cb() >>= fun () ->
        self # wait_for_tlog_release tlog_num
      in
      Collapser.collapse_many tlog_collection store_methods n cb' new_cb
    )

  method get_routing () =
    self # _read_allowed false >>= fun () ->
    Lwt.catch
      (fun () ->
        store # get_routing ()
      )
      (fun exc ->
        match exc with
          | Store.CorruptStore ->
            begin
              Lwt_log.fatal "CORRUPT_STORE" >>= fun () ->
              Lwt.fail Server.FOOBAR
            end
          | ext -> Lwt.fail ext)


  method get_key_count () =
    self # _read_allowed false >>= fun () -> 
    store # get_key_count ()

  method private quiesce_db () =
    self # _not_if_master () >>= fun () ->
    let result = ref Multi_paxos.Quiesced_fail in
    let sleep, awake = Lwt.wait() in
    let update = Multi_paxos.Quiesce (sleep, awake) in
    Lwt_log.debug "quiesce_db: Pushing quiesce request" >>= fun () ->
    push_node_msg update >>= fun () ->
    Lwt_log.debug "quiesce_db: waiting for quiesce request to be completed" >>= fun () ->
    sleep >>= fun res ->
    result := res;
    Lwt_log.debug "quiesce_db: db is now completed" >>= fun () ->
    match res with
      | Multi_paxos.Quiesced_ok -> Lwt.return () 
      | Multi_paxos.Quiesced_fail_master ->
        Lwt.fail (XException(Arakoon_exc.E_UNKNOWN_FAILURE, "Operation cannot be performed on master node"))
      | Multi_paxos.Quiesced_fail ->
        Lwt.fail (XException(Arakoon_exc.E_UNKNOWN_FAILURE, "Store could not be quiesced"))
  
  method private unquiesce_db () =
    Lwt_log.debug "unquiesce_db: Leaving quisced state" >>= fun () ->
    let update = Multi_paxos.Unquiesce in
    push_node_msg update 
      
  method try_quiesced f =
    self # quiesce_db () >>= fun () ->
    begin 
      Lwt.finalize
      ( f ) 
      ( self # unquiesce_db )
    end

  method optimize_db () =
    Lwt_log.debug "optimize_db: enter" >>= fun () ->
    self # try_quiesced( store # optimize ) >>= fun () ->
    Lwt_log.debug "optimize_db: All done"
 
  method defrag_db () = 
    self # _not_if_master() >>= fun () ->
    Lwt_log.debug "defrag_db: enter" >>= fun () ->
    store # defrag() >>= fun () ->
    Lwt_log.debug "defrag_db: exit"


  method get_db m_oc =
    Lwt_log.debug "get_db: enter" >>= fun () ->
    begin
      match m_oc with
        | None ->
          let ex = XException(Arakoon_exc.E_UNKNOWN_FAILURE, "Can only stream on a valid out channel") in
          Lwt.fail ex
        | Some oc -> Lwt.return oc
    end >>= fun oc ->
    self # try_quiesced ( fun () -> store # copy_store oc ) >>= fun () ->
    Lwt_log.debug "get_db: All done"

  method get_cluster_cfgs () =
    begin
      match client_cfgs with
        | None ->
          store # range_entries ~_pf:__adminprefix
            ncfg_prefix_b4_o false ncfg_prefix_2far_o false (-1)
          >>= fun cfgs ->
          let result = Hashtbl.create 5 in
          let add_item (item: string*string) =
            let (k,v) = item in
            let cfg, _ = ClientCfg.cfg_from v 0 in
            let start = String.length ncfg_prefix_b4 in
            let length = (String.length k) - start in
            let k' = String.sub k start length in
            Hashtbl.replace result k' cfg
          in
          List.iter add_item cfgs;
          let () = client_cfgs <- (Some result) in
          Lwt.return result
        | Some res ->
          Lwt.return res
    end

  method set_cluster_cfg cluster_id cfg =
    let key = ncfg_prefix_b4 ^ cluster_id in
    let buf = Buffer.create 100 in
    ClientCfg.cfg_to buf cfg;
    let value = Buffer.contents buf in
    let update = Update.AdminSet (key,Some value) in
    _update_rendezvous self update no_stats push_update ~so_post:_mute_so >>= fun () ->
    begin
      match client_cfgs with
        | None ->
          let res = Hashtbl.create 5 in
          Hashtbl.replace res cluster_id cfg;
          Lwt_log.debug "set_cluster_cfg creating new cached hashtbl" >>= fun () ->
          Lwt.return ( client_cfgs <- (Some res) )
        | Some res ->
          Lwt_log.debug "set_cluster_cfg updating cached hashtbl" >>= fun () ->
          Lwt.return ( Hashtbl.replace res cluster_id cfg )
    end

  method get_fringe boundary direction =
    Lwt_log.debug_f "get_fringe %S" (Log_extra.string_option2s boundary) >>= fun () ->
    store # get_fringe boundary direction

  method drop_master () =
    if n_nodes = 1 
    then 
      let e = XException(Arakoon_exc.E_NOT_SUPPORTED, "drop master not supported for singletons")in
      Lwt.fail e
    else
      begin
        self # who_master () >>= function
          | None -> Lwt.return ()
          | Some m ->
            if m <> my_name
            then Lwt.return ()
            else 
              begin
                let (sleep, awake) = Lwt.wait () in
                let update = Multi_paxos.DropMaster (sleep, awake) in
                Lwt_log.debug "drop_master: pushing update" >>= fun () ->
                push_node_msg update >>= fun () ->
                Lwt_log.debug "drop_master: waiting for completion" >>= fun () ->
                sleep >>= fun () ->
                let delay = (float lease_expiration) +. 0.5 in
                Lwt_log.debug_f "drop_master: waiting another %1.1fs" delay >>= fun () ->
                Lwt_unix.sleep delay >>= fun () ->
                Lwt_log.debug "drop_master: completed"
              end
      end
end
