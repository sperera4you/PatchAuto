# PatchAuto
Automated Patch solution for ESXi servers


The script will prompt you for the following attributes.

Date = This is the release date of the build you want to achieve.
For ex: if the build you want is ESXi 6.0 EP 23 - 15169789 then as to this KB Article your release date is 12/05/2019 (in mm/dd/yyyy format). Please pay close attention to the date format since the script is asking for yyyy/mm/dd format.

Baseline Name = give out a meaningful and a identifiable name for this. Consider below format (<Version> - <Build Number>(Release Name))
ESXi 6.0 - EP23 - 15169789 (ESXi600-201912001)
ESXi 6.5 - P04 - 15256549 (ESXi650-201912002)
  
Cluster name = The cluster you are planning to patch

