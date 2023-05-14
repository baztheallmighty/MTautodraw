
# MTautodraw

## **1. What is MTAutodraw:**

MTAutodraw automatically draws physical, logical and routing diagrams based on output from switches, routers and firewalls show commands. The output is a Visio file with multiple tabs. Several csv files are also produced that contain a list of CDP neighbors, a list of LLDP neighbors, all vlans and all CIDR's(Layer 3 interfaces).


## **2. What is MTAutodraw good for:**

- Audits
- network discovery
- general understand of a network 
- The start of network documentation
- Difference before and after a network change


## **3. Supported devices:**

    Cisco Nexus
    Cisco IOS, XE-IOS
    Cisco ASA
    Checkpoint Firewalls
    Juniper switches
    Cisco XR may work if the config text format is the same. 



## **4. How to use MTAutodraw:**

**4.1 Data Collection**

You will need to collect the output of the following show commands into files as listed below. This data collection is not preformed by the script. You will need to do. It is recommed to do this via a script. A sample script/process can be found in AuditWithPlink.txt. This is a very simple and somewhat manual way of doing data collection.



**Cisco routers and switches:**

    show version (required)
    show run (required)
    show interface ( BETA )
    show interface status up
    show ip interface brief
    show cdp neighbors details
    show lldp neighbors detail
    show lldp neighbors
    show spanning-tree
    show mac address-table
    show ip arp
    show ip route
    show ip route vrf *
    File must be named in the following format “identifier. Show ip route vrf star.txt” this is due to windows not supporting the * character in file paths. 
    
**Cisco ASA:**

    show route
    show config
    show version
    show interface

**CheckPoint:**

    show config
    show route
    show version
    show interface

**Junos (XML format required) BETA :**

    show configuration | display xml | no-more
    show interface | display xml | no-more
    show spanning-tree bridge | display xml | no-more
    show spanning-tree interface detail | display xml | no-more
    show lldp neighbors | display xml | no-more
    show route all | display xml | no-more
    show version  | display xml | no-more


NOTE: show lldp neighbors and show lldp neighbors detail are both requires because ironically some information is not in show lldp neighbors detail for some devices. 


Files names must be in the format. This is used to group the show output per device. 

    identifier.[command].txt
    or
    Hostname.[command].txt
    or
    IPAddress.[command].txt

Examples:

    switch01.show run.txt
    switch01.show ip interface brief.txt
    switch01.show cdp neighbors detailsorip address.txt

or

    switchB.show run.txt
    switchB.show ip interface brief.txt
    switchB.show cdp neighbors detailsorip address.txt

or

    172.24.30.36.show run.txt
    172.24.30.36.show cdp neighbors detail.txt
    172.24.30.36.show interface status up.txt

NOTE: Ensure that your files don't have banner lines within them. It must be just the result of the command and no extra text. You can use a multiline replace tool if you need to. Notepad++ has a plugin called Toolbucket that works really well for this. 


**4.2 File storage**

Put all the files into a folder on your local computer.  

**4.3 Prerequisites**

- Python with TextFSM module installed. 
- Powershell Visio module installed. This can be done with the command "Install-Module visio"


**4.4 Setup Environment** 

Open configurationVariables.ps1 with your preferred text editor and set the location of your python installed. $GPathToPythonExe=
Note: Other values can be edited in this file to change what is drawn, how it's drawn and to skip drawing things like telephones on physical diagrams. 


**4.5 Run the script**

Run the script and point it at that folder.
.\AutoDraw.ps1 -GDirectory c:\ShowCommandsFolder -GPathToScript c:\autodraw\ -GOutPutDirectory c:\OutputFolder

GDirectory: This is the directory where all of your show commands are stored

GPathToScript: This is the path to the script. It is used to reference templates,etc

GOutPutDirectory: This is where you want to output your visio files.


## **5. Unknown issues / Common problems:**

**5.1	There are TextFSM Errors in the log file:**

This normally occurs because the format of the input file e.g show ip arp contains extra unexpected text. 
Banners, command prompt text e.g "SwitchHostname#show run" or "-more-" , etc.
This extra text needs to be removed. 

**5.2	File names**

If you get the error “File doesnt exist:” or “No show run files found. Please check the name of your files. e.g HostID.show run.txt” this means there is something wrong with the naming convention of your files. Check the names of your files. 

**5.3 Limitations**

    The script is slow
    The scale and text size is wrong
    This script has only very limited testing
    Duplicate hostnames result in the script throwing an error ( Requires manual rename)
    Junos has had very minimal testing
    Junos LLDP interface matching uses port descriptions, this can result in inaccurate diagrams.
    No spanning tree for Junos yet
    Only RVSTP has been tested
    Cisco & cisco ASA show ip arp with VRF’s is not implemented
    LLDP and CDP need to be enabled on devices to get physical diagrams
    

## **6. Good practices**

    Text files should use UTF-8 encoding
    Break the work load up into useful units e.g buildings, racks, core / edge devices, etc
    More than 25 devices per diagram generally results in a very messy diagram


## **6. Acknowledgements**
I would like to say thank you to the following people for there libraries and hard work:

Brians worth GetIPv4Subnet.psm1

Jason Edelman Netcode Templates for Textfsm  

Saveen Reddy Visio Automation 
