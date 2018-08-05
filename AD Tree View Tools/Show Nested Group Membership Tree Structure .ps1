# Copyright (c) 2018 Kevin Ott
# Licensed under the MIT License
# See the LICENSE file in the project root for more information.

<# 
.SYNOPSIS
	Returns a text-based tree of all nested group memberships for the specified initial object.
.DESCRIPTION
    This script outputs a text-based tree of Active Directory group memberships
    similar to what is output by the windows command-line "tree" command. The script
    output will show all nested group memberships of the specified initial AD object and
    the structure of those memberships. By default, the script will use write-host to
    present the output with color, but obviously cannot be piped. Using the -MakePipeable
    flag will force the script to use write-output and allow piping of the result.
    The output of the script will flag any circular group nesting. This script assumes
    that any cross-domain memberships will be from domains that are resolve-able in DNS
    and can be read by the executing account. Powershell 3.0 and higher is required.
.EXAMPLE
	& '.\Show Nested Group Membership Tree Structure.ps1' -ObjectName 'System Administrators' -FullDomainName ad.example.com
    Displays the tree structure for the group 'system administrators' in the domain ad.example.com
.EXAMPLE
    & '.\Show Nested Group Membership Tree Structure.ps1' -ObjectName 'Administrator' -FullDomainName ad.example.com -Make Pipeable | Add-Content -Path .\output.txt -Encoding Unicode
    Outputs the tree structure for the user 'administrator' in the domain ad.example.com to 'output.txt'
.PARAMETER ObjectName
    The name of the Active Directory object for which the resulting nested membership
    tree structure will be shown. This can be a user, computer, or group object. The object name
    must be used, as opposed to the display name or samaccount name in the case of a user.
.PARAMETER FullDomainName
    The full name of the domain where the initial object resides. This is a required variable
    only to ensure that expected results are always derived when querying across domains. If you
    have only one domain, you might consider unseting this as a required parameter.
.PARAMETER MakePipeable
    Switch to switch the results from a colorized output using write-host to an uncolorized output
    that uses write-output and is therefore pipeable. *Please note* if you do plan to pipe the output
    to a text file, you should ensure you are using Unicode encoding if you want the results to look the
    same as they do in the powershell window. See example two.
.NOTES
    Filename: Show Nested Member Tree Structure.ps1
    Date: 6/11/2018
    Author: Kevin Ott
#Requires -Version 3
.LINK
    https://github.com/KevOtt/
#> 

[cmdletbinding()]

Param(
    [Parameter(Mandatory=$True)]
    [string]$ObjectName,
    [Parameter(Mandatory=$True)]
    [string]$FullDomainName,
    [switch]$MakePipeable
)


## Functions

function Query-ADObject{
    <#
    .SYNOPSIS
        Returns details on a specific AD Object.
    .DESCRIPTION
        Takes a directory searcher object, domain name, and
        object name as input and returns a ResultPropertyCollection
        containing properties of the object.
    .LINK
    https://github.com/KevOtt/AD-Tools
    #>
    
    param(
        [Parameter(Mandatory = $true)]
        [string]$ObjectName,
        [Parameter(Mandatory = $true)]
        [System.DirectoryServices.DirectorySearcher]$DirectorySearcher,
        [Parameter(Mandatory = $true)]
        [string]$Domain
        )

        # Set our filter to the specified object name
        $DirectorySearcher.Filter = ("Name=" + $ObjectName)
        # Convert domain from fqdn format to ldap query format and set as search root
        $DirectorySearcher.SearchRoot =  ('LDAP://' + (@(ForEach($s in ($Domain.Split('.'))) {('DC=' + $s)}) -join ','))
        
        # return fist result object found
        return ($DirectorySearcher.FindOne().Properties)
}

Function Return-HeirarchyObject{
    <#
    .Synopsis
        Returns a custome heirarchy object.
    .DESCRIPTION
        Takes a DictionaryBase object containing the standard properties
        for an AD object and returns a custom heirarchy object used to build
        the output.
    .LINK
    https://github.com/KevOtt/AD-Tools
    #>

    param(
        [System.Collections.DictionaryBase]$AdObject
        )
    $distName = (($AdObject.distinguishedname)[0]).ToString()

    Return (
        New-Object -TypeName PSObject -Property (@{`
        'Name' = (($AdObject.name)[0]).ToString();
        'SamAccountName' = $AdObject.samaccountname;'DistName'= $distName;`
        'Domain'= @(($distname.Split(',') -match 'DC=') | ForEach-Object{$_.trimStart('DC=')}) -join '.';`
        'GUID'= (@((($AdObject.objectguid)[0]) | ForEach-Object {$_.ToString('x')}) -join '');
        'Type' = ((((($ADObject.objectcategory)[0]).ToString()).Split(','))[0]).Remove(0,3);`
        'Parent' = '';'Queried'=$False;'Written' = $False;'ID'=''})
        )
}

## Setup

# Parse quotes from all input parameters
$PSBoundParameters | Select-Object -ExpandProperty Keys | ForEach-Object{
    $v = (Get-Variable -Name $_ -ValueOnly -ErrorAction SilentlyContinue)
    if($v -ne $null -and ($v.GetType().Name) -eq 'string'){
        Set-Variable -Name $V -Value ((Get-Variable -Name $_ -ValueOnly) -replace "['`"]",'')
        }
    }

# Test Resolve Initial Domain
TRY{
    [System.Net.Dns]::gethostaddresses($FullDomainName) | Out-Null
    }
CATCH [System.Management.Automation.MethodInvocationException]{
    throw "Cannot resolve $FullDomainName in DNS. Is this the full domain name?"
    }

# Create ADSI searcher object
TRY{
    $Global:DirectorySearcher = New-Object System.DirectoryServices.DirectorySearcher -ErrorAction Stop
    }
Catch{
    throw 'Unable to construct directory searcher object. Ensure .NET is installed and you are not running Powershell Core'
    }


## Getting Group membership details

# Null heirarchy array in case running from ISE
$AllGroups = @()

# Return initial object details and create heirarchy object
Write-Verbose ('Getting details of initial object: ' + $ObjectName)
$init = Query-ADObject -DirectorySearcher $Global:DirectorySearcher -Domain $FullDomainName -ObjectName $ObjectName
# If object not found, stop script
if($init -eq $null){
    throw "Cannot find object $ObjectName, are you sure it exists?"
}
$g = Return-HeirarchyObject -AdObject $init
$g.ID = '0'
$g.Parent = '/'


$AllGroups += $g

# Loop through any groups to get nested groups
$i = 1
while(@($AllGroups.Queried) -contains $false){
    Write-Verbose 'loop'
    $AllGroups | Where-Object {$_.Queried -eq $false} | ForEach-Object {
        # Set loop variable to current group object
        Write-Verbose ('Getting details of group: ' + $p.Name)
        $p = $_

        # Get group memberships of the current object
        $memberships = (Query-ADObject -ObjectName $p.Name -DirectorySearcher $Global:DirectorySearcher -Domain $p.Domain).memberof 
        # If memberships not null, query each containing group
        if($memberships -ne $null){
            $memberships | ForEach-Object {
                # Parse name from distinguished name
                $tname = (($_.split(','))[0]).remove(0,3)
                # Parse full domain name from distinguished name
                $tdomain = @(($_.Split(',') -match 'DC=') | ForEach-Object{$_.trimStart('DC=')}) -join '.';`

                # Query AD for group and create heirarchy object
                $n = Return-HeirarchyObject -AdObject (Query-ADObject -ObjectName $tname -DirectorySearcher $Global:DirectorySearcher -Domain $tdomain)
                $n.ID = $i
                $n.Parent = $p.id
                if($n.Type -eq 'Person'){$n.Queried = 'NA'}
            
                if((($AllGroups | Where-Object {$_.ID -eq $p.parent}) | Select -ExpandProperty GUID) -eq $n.GUID){
                    $n.Name = ($n.Name + ' - Circular Nesting!')
                    $n.Queried = 'Skipped'
                }
                        
                $AllGroups += $n

                # Incriment our ID counter
                $i++
            }
        }
        $_.Queried = 'true'
    }
}



## Outputing tree

# Set initial parent
$CurrentParent = '/'
$Output = @()

# Loop until every object is added to output array
while(@($AllGroups | Where-Object {$_.Written -eq $false}).count -ne 0){

    # Was the last thing written the last child for the current parent?
    if($CurrentParent -ne '/' -and @(($AllGroups | ?{$_.Parent -eq $currentparent -and $_.Written -match 'false'})).Count -eq 0){
        # Change parent and indent
        # Using [0] here to make sure we don't get more than one instance of root returned
        $currentParent = ($AllGroups | Where-Object {$_.id -eq $CurrentParent}).Parent[0]
        $CurrentIndent = (($CurrentIndent.Substring(0,($CurrentIndent.Length - 12))) + '├─────')
        }

    # Is current parent root?
    if($CurrentParent -eq '/'){
        $CurrentIndent = '──────'
        }

    # Loop through children of current parent that have not been written
    $AllGroups | Sort-Object Type -Descending | Where-Object {$_.parent -eq $currentParent -and $_.Written -match 'false'} | %{
        
        # Set local variable
        $t = $_
        $isLastChild = $false

        # Determine if this is the last child for current parent
        if($T.Parent -ne '/' -and @(($AllGroups | Where-Object {$_.Parent -eq $currentparent -and $_.Written -match 'false'})).Count -eq 1){
            $isLastChild = $true
            # Change current indent to correct line
            $CurrentIndent = ($CurrentIndent.Substring(0,($CurrentIndent.Length -6)) + '┌─────')
            }

        # Add indent and object ID to output array
        $Output += @{$t.id = $CurrentIndent}
        
        # Set written flag on object
        $T.Written = 'true'


        # Does the current object have children?
        if(($AllGroups | Where-Object {$_.Parent -eq $t.id}) -ne $null){
            # Change current parent
            $currentParent = $t.id

            # If there are children and current object is the last child
            if($isLastChild -eq $true -and $t.Parent -ne '/'){
                $CurrentIndent = (($CurrentIndent.Substring(0,($CurrentIndent.Length - 6))) + '      ├─────')
                }
            # If there are children and current object's parent is root
            elseif($t.Parent -eq '/'){
                $CurrentIndent = (' '*($CurrentIndent.Length) + '├─────')
                }
            # All other cases
            else{
                $CurrentIndent = ( ($CurrentIndent.Substring(0,($CurrentIndent.Length - 6))) + '│     ' + '├─────')
                }
            }
        }
    }

# Write the output array
# Splitting it this way is a bit complicated, but allows us to 
# easily reverse the output order without having overly-complex logic

for($i = ($Output.Count - 1); $i -ge 0; $i--){

    $t = $AllGroups | Where-Object {$_.id -eq [int]([string]($Output[$i].Keys))}
    $PrintIndent = [string]($Output[$i].Values)
    
    # Determine output line color and content
    if($t.Parent -eq '/'){
        # Root group in cyan
        $Color = ([system.consolecolor]'green')
        # This could probably cleaner, determining output for root if not a group
        if($t.Type -eq 'group'){
            $Line = (($t.domain.split('.')[0]).ToUpper() + '/' + $t.Name.ToUpper())
            }
        else{
            if($t.SamAccountName -ne $t.Name){
                $Line =  ($t.SamAccountName.ToLower() + ' - ' + $t.Name)
                }
            else{
                $Line = $t.Name
                }
            }
        }
    elseif($t.Type -eq 'group' -and $t.Name -like '* - circular nesting!*'){
        # Error messages in red
        $Color = ([system.consolecolor]'red')
        $Line = (($t.domain.split('.')[0]).ToUpper() + '/' + $t.Name.ToUpper())
        }
    elseif($t.type -eq 'group'){
        # Otherwise green if group
        $Color = ([system.consolecolor]'cyan')
        $Line = (($t.domain.split('.')[0]).ToUpper() + '/' + $t.Name.ToUpper())
        }
    elseif($t.Type -eq 'computer'){
        $Color = ([system.consolecolor]'gray')
        $Line = ($t.SamAccountName.ToLower() + ' - ' + $t.Name)
        }
    else{
        # If name and samaccount name are different, show both for clarity
        if($t.SamAccountName -ne $t.Name){
            $Line =  ($t.SamAccountName.ToLower() + ' - ' + $t.Name)
            }
        else{
            $Line = $t.Name
            }
        $Color = $null
        }
        
    # Write the output line

    # If running with -MakePipeable, we need to use write-output instead of write host,
    # no color option, but then the content is pipeable. 
    if($MakePipeable -eq $true){
        Write-Output ($PrintIndent + $Line)
        }
    else{
        if($color -ne $null){
            Write-Host $PrintIndent -NoNewline
            Write-Host $Line -ForegroundColor $Color
            }
        else{
            Write-Host ($PrintIndent + $Line)
            }
        }
    }
Write-Output ''