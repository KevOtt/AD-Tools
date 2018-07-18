# Copyright (c) 2018 Kevin Ott
# Licensed under the MIT License
# See the LICENSE file in the project root for more information.


Function Query-ADGroupMembers{
    <#
    .SYNOPSIS
        Returns details on the members of a group.
    .DESCRIPTION
        This is a function for returning member of an AD group without needing
        the Active Directory Powershell module installed. The function is essentially a wrapper
        for running an LDAP query with the .Net Directory searcher. Assumes that the executing account
        has appropriate read access to the domain. Requires the distinguished group name. Returns an array
        of ResultPropertyCollection. Note that this function will not work to return members of the groups 
        domain users or domain computers.
    .EXAMPLE
        Query-ADGroupMembers -GroupDistinguishedName 'CN=Shared Calendar RW,OU=Groups,DC=example,DC=com'
        Retrieve details on any objects which are members of the specified group in the current forest.
    .EXAMPLE
	    Query-ADGroupMembers -GroupDistinguishedName 'CN=Admins RW,OU=Groups,DC=example,DC=com' -UsersOnly
        Retrieve details on any users which are members of the specified group in the current forest.
    .PARAMETER GroupDistinguishedName
        Distinguished name of the group to return member details.
    .PARAMETER ForestName
        Domain name of the forest where the group resides. If not specified, the current forest will be used.
    .PARAMETER UsersOnly
        Specifies that details will only be returned for group members that are user objects rather than other groups, computers, etc.
    .NOTES
        Filename: Function Query-ADGroupMembers.ps1
        Version: 1.0
        Date: 7/12/2018
        Author: Kevin Ott
    .LINK
    https://github.com/KevOtt/AD-Tools
    #>
    
    param(
        [Parameter(Mandatory = $true, Position=0)]
        [string]$GroupDistinguishedName,
        [switch]$UsersOnly,
        [string]$ForestName
        )

        # If no forest name was provided, determine current forest
        if($ForestName -eq $null -or $ForestName -eq ''){
            $ForestName = ([System.DirectoryServices.ActiveDirectory.Forest]::GetCurrentForest().RootDomain.Forest.Name.ToString())
            }
        $GC = ('GC://' + (@(ForEach($s in ($ForestName.Split('.'))) {('DC=' + $s)}) -join ','))
        
        # Return object from the GC catalog of the targeted forest
        $DirectorySearcher = New-Object ([System.DirectoryServices.DirectorySearcher])   
        $DirectorySearcher.SearchRoot = $GC
        $DirectorySearcher.Filter = "(&(objectClass=group)(DistinguishedName=$GroupDistinguishedName))"
        # Re-throw any exceptions from FindOne() as terminating errors
        TRY{
        $ADObject = $DirectorySearcher.FindOne().properties
            }
        CATCH{
            throw $_.exception
            }
            
        # Check for null return
        if($ADObject -eq $null){
            throw ('Group not found')
            }
        
        # Determine search root based on group scope, global group membership has to be searched
        # in the LDAP root, universal and domain local group membership needs to be searched in the GC root
        if(($ADObject.grouptype)[0] -band 2){
            $DirectorySearcher.SearchRoot = ('LDAP://' + (($GroupDistinguishedName.Split(',') | Where-Object{$_ -like 'DC*'}) -join ','))
            }

        # Set filter based on switch
        $DirectorySearcher.Filter = "memberof=$GroupDistinguishedName"
        if($UsersOnly){
            $DirectorySearcher.Filter = "(&(objectClass=user)(memberof=$GroupDistinguishedName))"
            }

        # Return all objects
        return @($DirectorySearcher.FindAll().Properties)
}
