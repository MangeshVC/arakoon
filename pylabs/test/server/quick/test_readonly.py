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



from .. import system_tests_common as C

from nose.tools import *
from arakoon.ArakoonExceptions import *

@C.with_custom_setup(C.setup_1_node, C.basic_teardown)
def test_read_only():
   cluster = C._getCluster()
   client = C.get_client()
   v = 'XXX'
   client ['xxx']= v
   cluster.stop()
   cluster.setReadOnly()
   cluster.start()
   assert_raises(ArakoonException, client.set, 'xxx','yyy')
   client = C.get_client()
   xxx = client['xxx']
   assert_equals(xxx,v)
   
