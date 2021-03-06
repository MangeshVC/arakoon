"""
Copyright (2010-2014) INCUBAID BVBA

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
"""



from .. import system_tests_common as Common
import nose.tools as NT
import time
import logging

@Common.with_custom_setup(Common.setup_3_nodes, Common.basic_teardown)
def test_preferred_master():
    cluster = Common._getCluster(Common.cluster_id)
    cluster.stop()
    pm = Common.node_names[0]
    cluster.preferredMasters([pm])
    cluster.start()
    time.sleep(1.0)
    Common.assert_running_nodes(3)
    time.sleep(4.0 * Common.lease_duration)
    logging.info("all should be well")
    client = Common.get_client()
    master = client.whoMaster()
    NT.assert_equals(pm, master)

    logging.info("master indeed is `%s`", pm)
    client.dropConnections()
    del client
    cluster.stopOne(pm)
    delay = 8.0 * Common.lease_duration

    logging.info("stopped master, waiting for things to settle (%fs)", delay)
    time.sleep(delay)
    client = Common.get_client()
    master2 = client.whoMaster()
    logging.info("master2 = %s",master2)
    NT.assert_equals(True, master2 != pm)
    logging.info("node %s took over, now restarting preferred master", master2)
    cluster.startOne(pm)
    logging.info("waiting for things to settle")
    time.sleep(4.0* Common.lease_duration)
    client = Common.get_client()
    master3 = client.whoMaster()
    logging.info("master3 = %s", master3)
    NT.assert_equals(master3,pm)

    # node should no longer be preferred after the dropMaster call
    Common.dropMaster(pm)
    client.nop()
    master4 = client.whoMaster()
    NT.assert_not_equals(master4, pm)

    # perform maintenance on node to make it behave in a preferred manner again
    Common.defragDb(pm)

    time.sleep(2 * Common.lease_duration)
    client.nop()
    master5 = client.whoMaster()
    NT.assert_equals(master5, pm)


@Common.with_custom_setup(lambda h: Common.setup_n_nodes(5, False, h), Common.basic_teardown)
def test_preferred_masters():
    # Get reference to the cluster
    cluster = Common._getCluster(Common.cluster_id)
    cluster.stop()

    # 2 of 5 nodes are preferred masters
    preferred_masters = Common.node_names[:2]

    cluster.preferredMasters(preferred_masters)

    # Launch cluster and wait until it's up-and-running
    cluster.start()
    time.sleep(1.0)
    Common.assert_running_nodes(5)

    time.sleep(4.0 * Common.lease_duration)
    logging.info('Cluster running')

    # *** Check 1: make sure one of the preferred masters is elected as master
    client = Common.get_client()
    master = client.whoMaster()
    logging.info('Current master: %s', master)
    assert master in preferred_masters

    client.dropConnections()
    del client

    # Kill all preferred masters
    for master in preferred_masters:
        cluster.stopOne(master)

    delay = 8.0 * Common.lease_duration

    logging.info('Stopped preferred masters, waiting for callback to take over')
    time.sleep(delay)
    client = Common.get_client()
    master = client.whoMaster()
    logging.info('Backup master: %s', master)
    assert master not in preferred_masters

    # *** Check 2: make sure whenever a preferred master is available, it
    # becomes master
    logging.info(
        'Restarting preferred masters one by one, making sure they take over')
    for preferred_master in preferred_masters:
        logging.info('Launching preferred master "%s"', preferred_master)
        cluster.startOne(preferred_master)

        logging.debug('Waiting for things to settle')
        time.sleep(4.0 * Common.lease_duration)

        client = Common.get_client()
        master = client.whoMaster()
        logging.info('Current master: %s', master)

        assert master == preferred_master

        logging.info('Killing master')
        cluster.stopOne(master)

        logging.info('Stopped master, waiting for things to settle')
        time.sleep(delay)
        client = Common.get_client()
        master = client.whoMaster()

        logging.info('Node "%s" took over', master)

        assert master not in preferred_masters

    logging.info('Starting all preferred master nodes')
    for preferred_master in preferred_masters:
        cluster.startOne(preferred_master)

    logging.debug('Waiting for things to settle')
    time.sleep(delay)

    # *** Check 3: as long as one of the preferred masters is running, it should
    # be elected as the master
    preferred_masters_2 = list(preferred_masters)
    while True:
        if len(preferred_masters_2) == 0:
            break

        client = Common.get_client()
        master = client.whoMaster()

        logging.info('Current master: %s', master)

        assert master in preferred_masters_2

        logging.info('Killing master')
        cluster.stopOne(master)
        preferred_masters_2.remove(master)

        logging.debug('Waiting for things to settle')
        time.sleep(delay)
