"""
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
"""


from system_tests_common import *
import logging
import subprocess

import time
import threading

def _getCluster():
    global cluster_id
    return q.manage.arakoon.getCluster(cluster_id)

@with_custom_setup( default_setup, basic_teardown )
def test_single_client_100000_sets():
    iterate_n_times( 100000, simple_set )

@with_custom_setup( setup_3_nodes_forced_master, basic_teardown )
def test_delete_non_existing_with_catchup ():
    stopOne( node_names[1] )
    key='key'
    value='value'
    cli = get_client()
    try:
        cli.delete( key )
    except:
        pass
    cli.set(key,value)
    cli.set(key,value)
    cli.set(key,value)
    
    slave = node_names[1]
    startOne( slave )
    time.sleep(2.0)
    cluster = q.manage.arakoon.getCluster(cluster_id)
    log_dir = cluster.getNodeConfig(slave ) ['log_dir']
    log_file = q.system.fs.joinPaths( log_dir, '%s.log' % slave )
    log = q.system.fs.fileGetContents( log_file )
    assert_equals( log.find( "don't fit" ), -1, "Store counter out of sync" )
    
@with_custom_setup( setup_2_nodes_forced_master, basic_teardown )
def test_expect_progress_fixed_master ():
    stopOne( node_names[1] )
    key='key'
    value='value'
    cli = get_client()
    try:
        cli.set(key,value)
    except:
        pass
    restart_all()
    time.sleep(1.0)
    assert_true( cli.expectProgressPossible(),
                 "Master store counter is ahead of slave" )
    
@with_custom_setup( setup_3_nodes_forced_master, basic_teardown )
def test_restart_single_slave_long ():
    restart_single_slave_scenario( 100, 10000 )

@with_custom_setup( default_setup, basic_teardown )
def test_20_clients_1000_sets() :
    arakoon.ArakoonProtocol.ARA_CFG_TIMEOUT = 60.0
    create_and_wait_for_threads ( 20, 1000, simple_set, 200.0 )

@with_custom_setup( setup_3_nodes, basic_teardown)
def test_tlog_rollover():
    iterate_n_times( 150000, simple_set )
    stop_all()
    start_all()
    iterate_n_times( 150000, simple_set )

@with_custom_setup( setup_2_nodes, basic_teardown)
def test_catchup_while_collapsing():
    iterate_n_times( 2*tlog_entries_per_tlog, simple_set )
    
    stop_all()
    whipe( node_names[0] )
    startOne(node_names[1])
    
    delayed_start = lambda: startOne(node_names[0])
    collapser = lambda: collapse(node_names[1] )
    
    create_and_wait_for_thread_list( [delayed_start, collapser] )
    cli = get_client()
    
    time_out = 120
    iter_cnt = 0
    
    while iter_cnt < time_out :
        assert_running_nodes ( 2 )
        if cli.expectProgressPossible() :
            break
        iter_cnt += 1
        time.sleep(1.0)
        
    stop_all()
    assert_last_i_in_sync( node_names[0], node_names[1])
    compare_stores( node_names[0], node_names[1] )
    pass   

@with_custom_setup( default_setup, basic_teardown )
def test_restart_master_long ():
    restart_iter_cnt = 10
    write_loop = lambda: iterate_n_times( 100000, retrying_set_get_and_delete, failure_max=2*restart_iter_cnt, valid_exceptions=[ArakoonSockNotReadable,ArakoonNotFound] )
    restart_loop = lambda: delayed_master_restart_loop( restart_iter_cnt , 1.5*lease_duration )
    global test_failed
    test_failed = False 
    create_and_wait_for_thread_list( [restart_loop, write_loop] )

    cli = get_client()
    time.sleep(2.0)
    key = "key"
    value = "value"
    cli.set(key, value)
    set_value = cli.get(key)
    assert_equals(  value, set_value , 
        "Key '%s' does not have expected value ('%s' iso '%s')" % (key, set_value, value) )
    
    stop_all()
    start_all()
    stop_all()
    
    assert_last_i_in_sync( node_names[0], node_names[1] )
    assert_last_i_in_sync( node_names[2], node_names[1] )
    compare_stores( node_names[0], node_names[1] )
    compare_stores( node_names[2], node_names[1] )
    cli._dropConnections()
    logging.info("end of `test_restart_master_long`")
    
@with_custom_setup( default_setup, basic_teardown ) 
def test_master_reelect():
    cli = get_client() 
    master_id = cli.whoMaster()
    assert_not_equals ( master_id, None, "No master to begin with. Aborting.")
    
    key = "k"
    value = "v"
    cli.set(key ,value )

    logging.info("stopping master:%s", master_id)
    stopOne( master_id )

    delay = 1.5 * lease_duration
    time.sleep(delay)
    logging.info("waited %s, for reelection to happen" % delay)
    logging.info("config=%s" % (cli._config))
    
    cli._masterId = None
    
    new_master_id = cli.whoMaster()
    assert_not_equals ( new_master_id,
                        None,
                        "No new master elected, no master. Aborting.")
    assert_not_equals ( new_master_id,
                        master_id,
                        "No new master elected, same master. Aborting.")
    
    assert_equals( cli.get(key), value)
    startOne( master_id )
    
    # Give old master some time to catch up
    time.sleep( 5.0 )
    
    stopOne ( new_master_id )
    
    time.sleep( 2.0 * lease_duration )
    
    cli = get_client()
    newest_master_id = cli.whoMaster()
    assert_not_equals ( newest_master_id,
                        None,
                        "No new master elected, no master. Aborting.")
    assert_not_equals ( newest_master_id,
                        new_master_id,
                        "No new master elected, same master. Aborting.")


@with_custom_setup( setup_3_nodes, basic_teardown)
def test_large_tlog_collection_restart():
    
    iterate_n_times( 100002, simple_set )
    stop_all()
    start_all()
    iterate_n_times( 100, set_get_and_delete )
    

@with_custom_setup( setup_3_nodes, basic_teardown )
def test_3_node_stop_master_slaves_restart():
    
    logging.info( "starting test case")
    iterate_n_times( 1000, simple_set )
    cli = get_client()
    master = cli.whoMaster()
    slaves = filter( lambda node: node != master, node_names )
    stopOne( master )
    logging.info ( lease_duration )
    nap_time = 2 * lease_duration
    logging.info( "Stopped master. Sleeping for %0.2f secs" % nap_time )
    
    print nap_time
    
    time.sleep( nap_time )
    logging.info( "Stopping old slaves")
    for node in slaves:
        print "Stopping %s" % node
        stopOne( node )
    
    logging.info( "Starting old master")
    startOne( master )
    time.sleep(0.2)
    
    logging.info( "Starting old slaves")
    for node in slaves:
        startOne( node )
    
    cli._dropConnections()
    cli = get_client()
    
    logging.info( "Sleeping a while" )
    time.sleep( lease_duration / 2 )
    
    iterate_n_times( 1000, set_get_and_delete )
    cli._dropConnections()

@with_custom_setup( setup_2_nodes_forced_master , basic_teardown )
def test_missed_accept ():
    
    
    # Give the new node some time to recognize the master 
    time.sleep(0.5)
    stopOne( node_names[1] )
    
    cli = get_client()
    try:
        cli.set("k","v")
    except Exception, ex:
        logging.info( "Caught exception (%s: '%s'" , ex.__class__.__name__, ex )

    startOne ( node_names[1] )
    # Give the node some time to catch up
    time.sleep( 1.0 )
    
    iterate_n_times( 1000, set_get_and_delete )
    time.sleep(1.0)
    stop_all()
    assert_last_i_in_sync( node_names[0], node_names[1] )
    compare_stores( node_names[0], node_names[1] )

@with_custom_setup( setup_2_nodes_forced_master, basic_teardown)
def test_is_progress_possible():
    time.sleep(0.2)
    write_loop = lambda: iterate_n_times( 50000, retrying_set_get_and_delete  )
    create_and_wait_for_thread_list( [write_loop] )
   
    logging.info( "Stored all keys" ) 
    stop_all()

    whipe(node_names[1])

    cli = get_client()
    start_all()
    logging.info( "nodes started" )
    assert_false( cli.expectProgressPossible() )
    
    counter = 0
    max_wait = 60*5
    up2date = False
    
    while not up2date and counter < max_wait :
        time.sleep( 1.0 )
        counter += 1
        up2date = cli.expectProgressPossible()
    
    if counter >= max_wait :
        raise Exception ("Node did not catchup in a timely fashion")
    
    cli.set('k','v')


@with_custom_setup(setup_2_nodes, basic_teardown)
def test_collapse():
    zero = node_names[0]
    one = node_names[1]
    n = 298765
    iterate_n_times(n, simple_set)
    logging.info("did %i sets, now going into collapse scenario" % n)
    collapse(zero,1)
    logging.info("collapsing done")
    stopOne(one)
    whipe(one)
    startOne(one)
    cli = get_client()
    assert_false(cli.expectProgressPossible())
    up2date = False
    counter = 0
    while not up2date and counter < 100:
        time.sleep(1.0)
        counter = counter + 1
        up2date = cli.expectProgressPossible()
    logging.info("catchup from collapsed node finished")

@with_custom_setup(setup_1_node, basic_teardown)
def test_concurrent_collapse_fails():
    zero = node_names[0]

    n = 298765
    iterate_n_times(n, simple_set)
    logging.info("Did %i sets, now going into collapse scenario", n)

    class SecondCollapseThread(threading.Thread):
        def __init__(self, sleep_time):
            threading.Thread.__init__(self)

            self.sleep_time = sleep_time
            self.exception_received = False

        def run(self):
            logging.info('Second collapser thread started, sleeping...')
            time.sleep(self.sleep_time)

            logging.info('Starting concurrent collapse')
            rc = collapse(zero, 1)

            logging.info('Concurrent collapse returned %d', rc)

            if rc == 255:
                self.exception_received = True

    s = SecondCollapseThread(5)
    assert not s.exception_received

    logging.info('Launching second collapser thread')
    s.start()

    logging.info('Launching main collapse')
    collapse(zero, 1)

    logging.info("collapsing finished")

    assert_true(s.exception_received)

@with_custom_setup(setup_2_nodes_forced_master, basic_teardown)
def test_catchup_exercises():
    time.sleep(1.0) # ??
    
    def do_one(n, max_wait):
        iterate_n_times(n, simple_set)
        stop_all()
        logging.info("stopped all nodes")
        whipe(node_names[1])

        start_all()
        cli = get_client ()
        counter = 0
        up2date = False

        while not up2date and counter < max_wait :
            time.sleep( 1.0 )
            counter += 1
            up2date = cli.expectProgressPossible()
            logging.info("up2date=%s", up2date)
    
        if counter >= max_wait :
            raise Exception ("Node did not catchup in a timely fashion")

    n = 20000
    w = 40 # 500/s should be more than enough even for dss driven vmachines
    for i in range(5):
        do_one(n,w)
        n = n * 2
        w = w * 2

@with_custom_setup(setup_2_nodes_forced_master, basic_teardown)
def test_catchup_only():
    iterate_n_times(123000,simple_set)
    n0 = node_names[0]
    n1 = node_names[1]
    stopOne(n1)
    whipe(n1)
    logging.info("catchup-only")
    catchupOnly(n1)
    logging.info("done with catchup-only")
    stopOne(n0)
    compare_stores(n1,n0)

@with_custom_setup( setup_1_node_forced_master, basic_teardown )
def test_sso_deployment():
    global test_failed
    test_failed = False 
    
    write_loop = lambda: iterate_n_times( 10000, retrying_set_get_and_delete )
    large_write_loop = lambda: iterate_n_times( 280000, retrying_set_get_and_delete, startSuffix = 1000000 ) 
    write_thr1 = create_and_start_thread ( write_loop )
    non_retrying_write_loop = lambda: iterate_n_times( 10000, set_get_and_delete, startSuffix = 2000000  )
    
    add_node( 1 )
    cl = _getCluster()
    cl.setLogLevel("debug")
    
    regenerateClientConfig()
            
    restart_nodes_wf_sim( 1 )
    n1 = node_names[1]
    logging.info("going to start %s", n1)
    startOne(n1 )
    
    create_and_wait_for_thread_list ( [ large_write_loop ] )
    
    add_node( 2 )
    cl = _getCluster()
    cl.setLogLevel("debug")
    cl.forceMaster(None )
    logging.info("2 node config without forced master")

    regenerateClientConfig()
    
    restart_nodes_wf_sim( 2 )
    startOne( node_names[2] )
    time.sleep( 0.3 )
    assert_running_nodes ( 3 )
    
    write_thr3 = create_and_start_thread ( non_retrying_write_loop )

    write_thr1.join()
    write_thr3.join()
    
    assert_false ( test_failed )
    
    assert_running_nodes( 3 )
    
    
@with_custom_setup( setup_3_nodes, basic_teardown )
def test_3_nodes_2_slaves_down ():
    
    cli = get_client()
    master_id = cli.whoMaster()
    
    slaves = filter( lambda n: n != master_id, node_names )
    for slave in slaves:
        stopOne( slave )
    
    assert_raises( ArakoonSockNotReadable, cli.set, 'k', 'v' )
            
    cli._dropConnections()

@with_custom_setup( default_setup, basic_teardown )
def test_disable_tlog_compression():
    
    clu = _getCluster()
    clu.disableTlogCompression()
    clu.restart()
    time.sleep(1.0)
    
    tlog_size = get_entries_per_tlog() 
    
    num_tlogs = 2
    test_size = num_tlogs*tlog_size
    iterate_n_times(test_size, simple_set )
    
    logging.info("Tlog_size: %d", tlog_size)
    node_id = node_names[0]
    node_home_dir = clu.getNodeConfig(node_id) ['home']
    ls = q.system.fs.listFilesInDir
    time.sleep(2.0)
    tlogs = ls( node_home_dir, filter="*.tlog" )
    expected = num_tlogs + 1 
    assert_equals(len(tlogs), expected, "Wrong number of uncompressed tlogs (%d != %d)" % (expected, len(tlogs))) 
 