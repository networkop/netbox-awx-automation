# Network Automation with Netbox and Ansible AWX

The goal of this lab is to demonstrate how to use Ansible AWX (Tower) to configure Cumulus Linux devices based on information extracted from Netbox. This demo will walk you through the following actions:

* Initial Netbox configuration — populating the main Netbox data model with device information and IP address details.
* Configuring AWX — connecting AWX to use Netbox as an inventory source and pulling device and IPAM details from Netbox.
* Using Netbox as a configuration source of truth — populating Netbox with configuration context that will be used by Ansible playbooks to generate the final device config.

![](https://gitlab.com/nvidia-networking/systems-engineering/poc-support/netbox-awx-automation/-/raw/main/deployment.png)

> **NOTE**: For instructions on how to build the demo, see the see the [`./air`](https://gitlab.com/nvidia-networking/systems-engineering/poc-support/netbox-awx-automation/-/tree/main/air) directory.

## Lab details
| Device/Application | username | password | sw version | 
| -- | -- | -- | -- | 
| oob-mgmt-server | ubuntu | nvidia | Ubuntu 18.04 | 
| netq-ts | cumulus | cumulus | NetQ 4.0.0 |
| leaf01, leaf02 | cumulus | CumulusLinux! | CL 5.0 |
| netbox |  admin | admin | v3.0.11 | 
| AWX | admin | T6QokC7KZ9Xg1MdQr02selWNCOJjnHa0 | 19.5.0 |

In order to connect to the web UI of Netbox and AWX, we'll use SSH port forwarding. Navigate to the "Advanced" lab dashboard in Air and click "Enable SSH Service". Use the following command when connecting to the `oob-mgmt-server` (adjust SSH URL based on the generated host and port numbers):

```
ssh -L 8080:192.168.200.250:30329 -L 8081:192.168.200.250:32670 ssh://ubuntu@worker07.air.nvidia.com:22708
```

At this stage Netbox should become available on [localhost:8080](localhost:8080) and AWX is available on [localhost:8081](localhost:8081).

## 1. Configuring Netbox

The default way of interacting with Netbox is via its web UI, however, in this demo instead of including dozens of screenshots, we'll be using the [netbox shell](https://netbox.readthedocs.io/en/stable/administration/netbox-shell/) in order to configure Netbox programmatically. 


Connect to the `netq-ts` node and start a shell inside the `citc-netbox` Pod:

```bash
ubuntu@oob-mgmt-server:~$ ssh cumulus@netq-ts
cumulus@netq-ts:~$ sudo -i
root@netq-ts:~# kubectl exec -it deploy/citc-netbox bash
source /opt/netbox/venv/bin/activate
/opt/netbox/netbox/manage.py nbshell
```

Start by creating the basic netbox object model layout with [site](https://netbox.readthedocs.io/en/stable/core-functionality/sites-and-racks/#sites), [device role](https://netbox.readthedocs.io/en/stable/core-functionality/devices/#device-roles) and [manufacturer](https://netbox.readthedocs.io/en/stable/core-functionality/device-types/#manufacturers) details. 

```python
Site(name="CITC", status="active").save()
site = Site.objects.get(name="CITC")

DeviceRole(name="leaf").save()
role = DeviceRole.objects.get(name="leaf")

Manufacturer(name="nvidia").save()
m = Manufacturer.objects.get(name="nvidia")

DeviceType(model="vx", manufacturer=m).save()
t = DeviceType.objects.get(model="vx")

InterfaceTemplate(name="eth0", device_type=t, mgmt_only=True).save()
InterfaceTemplate(name="lo", device_type=t).save()
for i in range(1,3): 
	InterfaceTemplate(name=f"swp{i}", device_type=t, type="virtual").save()
```

Now we can put all these details together to add the two lab devices:

```python
Device(name="leaf01", device_role=role, site=site, device_type=t).save()
leaf01 = Device.objects.get(name="leaf01")
Device(name="leaf02", device_role=role, site=site, device_type=t).save()
leaf02 = Device.objects.get(name="leaf02")
```

Finally, populate Netbox IPAM with details required to configure the two lab devices:

```python
# create mgmt vrf and prefix
VRF(name="mgmt").save()
vrf_mgmt = VRF.objects.get(name="mgmt")
Prefix(prefix="192.168.200.0/24", vrf=vrf_mgmt).save()
prefix = Prefix.objects.get(prefix="192.168.200.0/24")

# get a pointer to `eth0` interface
leaf01_eth0 = Interface.objects.get(name="eth0", device=leaf01)
leaf02_eth0 = Interface.objects.get(name="eth0", device=leaf02)

# create OOB IP and assign it to `eth0` interface
IPAddress(address="192.168.200.2", vrf=vrf_mgmt, assigned_object=leaf01_eth0 ).save()
leaf01_ip = IPAddress.objects.get(address="192.168.200.2")
leaf01.primary_ip4=leaf01_ip
leaf01.save()

IPAddress(address="192.168.200.3", vrf=vrf_mgmt, assigned_object=leaf02_eth0 ).save()
leaf02_ip = IPAddress.objects.get(address="192.168.200.3")
leaf02.primary_ip4=leaf02_ip
leaf02.save()

# create `default` vrf and assign loopback ips
VRF(name="default").save()
vrf_default = VRF.objects.get(name="default")
Prefix(prefix="10.0.1.0/24", vrf=vrf_default ).save()

leaf01_lo = Interface.objects.get(name="lo", device=leaf01)
leaf02_lo = Interface.objects.get(name="lo", device=leaf02)

IPAddress(address="10.0.1.11", vrf=vrf_default, assigned_object=leaf01_lo ).save()
IPAddress(address="10.0.1.12", vrf=vrf_default, assigned_object=leaf02_lo ).save()
```

This is all what we need to populate basic Netbox data. This can be verified using Netbox UI at [localhost:8080](localhost:8080).


## 2. Configuring AWX

In order to use Netbox inventory source, we need to provide a way to pass authentication details to the [plugin](https://docs.ansible.com/ansible/latest/collections/netbox/netbox/nb_inventory_inventory.html). To do that, add a new credential type for netbox. Navigate to Administration -> Credential Types -> Add

![](https://gitlab.com/nvidia-networking/systems-engineering/poc-support/netbox-awx-automation/-/raw/main/awx/credential-type.png)

Now we can create a new credential object with the details of the local Netbox instance:

![](https://gitlab.com/nvidia-networking/systems-engineering/poc-support/netbox-awx-automation/-/raw/main/awx/netbox-cred.png)

We also need to create a new credential to access the Cumulus Linux devices: 

![](https://gitlab.com/nvidia-networking/systems-engineering/poc-support/netbox-awx-automation/-/raw/main/awx/cl-creds.png)


The default AWX EE execution environment does not include some of the python libraries required to interact with Netbox, so we'd need to create a new one. The container image has already been pre-built, however should you decide to create a custom image, you can see how it can be done by looking at the `make ee` command. For now, create a new execution environment with the provided pre-built image:

![](https://gitlab.com/nvidia-networking/systems-engineering/poc-support/netbox-awx-automation/-/raw/main/awx/netbox-ee.png)

Now we need to tell AWX about where to find our playbooks and the inventory by creating a new Project:

![](https://gitlab.com/nvidia-networking/systems-engineering/poc-support/netbox-awx-automation/-/raw/main/awx/project.png)

Once saved, AWX will try to fetch the latest commit and should report the job status as "Success".

![](https://gitlab.com/nvidia-networking/systems-engineering/poc-support/netbox-awx-automation/-/raw/main/awx/project-success.png)


Create a new Inventory called "netbox" and Navigate to the "Sources" tab to add this git repo as a source and tie it together with the previously created credentails:

![](https://gitlab.com/nvidia-networking/systems-engineering/poc-support/netbox-awx-automation/-/raw/main/awx/inventory.png)

Once the source is created and synced, the two lab devices should appear under the "Hosts" tab of the inventory:

![](https://gitlab.com/nvidia-networking/systems-engineering/poc-support/netbox-awx-automation/-/raw/main/awx/hosts.png)


Now we can run the first end-to-end test by combining all of the previously configured elements in a single job template. 

![](https://gitlab.com/nvidia-networking/systems-engineering/poc-support/netbox-awx-automation/-/raw/main/awx/debug.png)


This job template will execute the "debug" playbook that will do the following:

* Pull all information about Netbox devices (model, type, IP)
* Pull information about all interfaces known to Netbox
* Pull all IPAM information from Netbox
* For each device, print all known information on to `stdout`

This is how you can verify the details that have been collected by this playbook.

![](https://gitlab.com/nvidia-networking/systems-engineering/poc-support/netbox-awx-automation/-/raw/main/awx/debug-success.png)



## 3. Configuration modelling in Netbox

It's quite common to refer to Netbox as the "networking source of truth", however in reality its scope is limited to inventory and IP address management. In order to model the entire network device configuration state, we'll use a feature called [configuration context](https://netbox.readthedocs.io/en/stable/models/extras/configcontext/) that was designed to store JSON data associated with different objects. In our case, we'll use this to store a simple BGP configuration for both of our lab devices. We'll use the Netbox's [hierarchical rendering](https://netbox.readthedocs.io/en/stable/models/extras/configcontext/#hierarchical-rendering) to define common configuration for groups of network devices and use [local context](https://netbox.readthedocs.io/en/stable/models/extras/configcontext/#local-context-data) to override any device-specific settings.

Let's start by defining the common data model that will be shared amongst all devices with "leaf" role. Connect back to the netbox shell as it was described in step #1.


```python
role_context = {'bgp': {'address_family': [{'name': 'ipv4_unicast',          
                             'redistribute': [{'type': 'connected'}]}],     
         'asn': 65000,                                                      
         'neighbors': [{'interface': 'swp1',                               
                        'peergroup': 'underlay',                            
                        'unnumbered': True},                                
                       {'interface': 'swp2',                               
                        'peergroup': 'underlay',                            
                        'unnumbered': True}],                               
         'peergroups': [{'name': 'underlay', 'remote_as': 'external'}]},    
 'interfaces': [{'name': 'swp1'}, {'name': 'swp2'}]}

role = DeviceRole.objects.get(name="leaf")
ConfigContext(name="leaf", data=role_context).save()
ctx = ConfigContext.objects.get(name="leaf")
ctx.roles.add(role)
```

For each individual device, override the default BGP AS number:

```python
leaf01 = Device.objects.get(name="leaf01")
leaf02 = Device.objects.get(name="leaf02")
leaf01.local_context_data = { "bgp": { "asn": 65001 }}
leaf02.local_context_data = { "bgp": { "asn": 65002 }}
leaf01.save()
leaf02.save()
```

To check the final state that will be rendered for "leaf01":

```python
import pprint
pp = pprint.PrettyPrinter(indent=2)
pp.pprint(leaf01.get_config_context())
OrderedDict([ ( 'bgp',
                OrderedDict([ ('asn', 65001),
                              ( 'neighbors',
                                [ { 'interface': 'swp1',
                                    'peergroup': 'underlay',
                                    'unnumbered': True},
                                  { 'interface': 'swp2',
                                    'peergroup': 'underlay',
                                    'unnumbered': True}]),
                              ( 'peergroups',
                                [ { 'name': 'underlay',
                                    'remote_as': 'external'}]),
                              ( 'address_family',
                                [ { 'name': 'ipv4_unicast',
                                    'redistribute': [ { 'type': 'connected'}]}])])),
              ('interfaces', [{'name': 'swp1'}, {'name': 'swp2'}])])
```

## 4. Using Netbox configuration context from AWX

Now that we have the data models defined in AWX, we can finally provision our lab devices.