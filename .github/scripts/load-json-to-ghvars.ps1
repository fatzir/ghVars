# $repository this script do not accept repository list /!\

param(
    [Parameter(Mandatory = $true)][string]  $path_to_file,
    [Parameter(Mandatory = $true)][string]  $repository
)

<#
.SYNOPSIS
Parse json file from path given in parameter, return a hashtable of the content

.PARAMETER InputObject
Parameter description

.EXAMPLE

    [System.Collections.Hashtable]$hashtable = [ordered]@{}
    #Read json file
    $json_var_file = Get-Content $path_to_file | ConvertFrom-Json
    ##root level : 'envs'
    $jsonObjects = $json_var_file.envs
    ##call ConvertTo-Hashtable function
    $hashtable = ConvertTo-Hashtable $jsonObjects

.NOTES
General notes
#>
function ConvertTo-Hashtable {
    [CmdletBinding()]
    [OutputType('hashtable')]
    param (
        [Parameter(ValueFromPipeline = $true)]
        $InputObject
    )
    process {

        if ($null -eq $InputObject) {
            return $null
        }

        if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]){
            $collection = @(
                foreach ($object in $InputObject) {
                    ConvertTo-Hashtable -InputObject $object
                }
            )
            Write-Output -NoEnumerate $collection
        } elseif ($InputObject -is [psobject]){
            $hash = @{}
            foreach ($property in $InputObject.PSObject.Properties) {
                $hash[$property.Name] = ConvertTo-Hashtable -InputObject $property.Value
            }
            $hash
        } else {
            $InputObject
        }
    }
}

<#
.SYNOPSIS
search and resolve an anchor, return a string value of the 

.PARAMETER Balise
.PARAMETER CurrentEnv
.PARAMETER CurrentRecord
.PARAMETER InputObject

.EXAMPLE
$anchor_value = Get-AnchorValue $BaliseBody $env $currentRecord $InputObject

.NOTES
General notes
#>
function Get-AnchorValue {
    [CmdletBinding()]
    [OutputType([String])]
    param (
        [Parameter()][string] $Balise,
        [Parameter()][string] $CurrentEnv,
        [Parameter()][string] $CurrentRecord,
        [Parameter()][System.Collections.Hashtable] $InputObject
    )
    process {

        #debug
        #Write-Host "__input InputObject  $InputObject"
        #Write-Host "__input Balise  $Balise"
        #Write-Host "__input CurrentEnv  $CurrentEnv"
        #Write-Host "__input CurrentRecord  $CurrentRecord"

        #search in current env
        $MatchResult = $InputObject[$CurrentEnv].GetEnumerator() | Where-Object { $_.Name -eq $Balise }

        if ([string]::IsNullOrEmpty($MatchResult))
        {
            #Write-Host "- No match in env looking in repository level" 
            $MatchResult = $InputObject['repository'].GetEnumerator() | Where-Object { $_.Name -eq $Balise }
        }

        #match Found
        if (-not [string]::IsNullOrEmpty($MatchResult))
        {
            $result = $MatchResult.Value
            #Write-Host "++ Match Found :" $result
            Write-Output $result
        }
        else 
        {
            #Write-Host "** No match Found :" $Balise
        }
    }
}

<#
.SYNOPSIS
Take the hashtable from json file 
replace hashtable anchor values resolved from origin env and repository level
create github env (gh cli)
save all github vars (gh cli)

.PARAMETER InputObject
hashtable

.EXAMPLE
    [System.Collections.Hashtable]$hashtable = [ordered]@{}
    [System.Collections.Hashtable]$result = [ordered]@{}
    
    #Read json file
    $json_var_file = Get-Content $path_to_file | ConvertFrom-Json
    ##root level : 'envs'
    $jsonObjects = $json_var_file.envs
    ##call ConvertTo-Hashtable function
    $hashtable = ConvertTo-Hashtable $jsonObjects
    ##resolve all anchors '[#' '#]' in values and save the result in github vars
    $result = Replace-AnchorValueJson $hashtable
#>
function Replace-AnchorValueJson {
    [CmdletBinding()]
    param (
        [Parameter(ValueFromPipeline = $true)]
        [System.Collections.Hashtable]
        $InputObject
    )
    process {

        if ($null -eq $InputObject) {
            return $null
        }
        foreach ($env in $InputObject.Keys.Clone())
        {
            #Write-Host "** env : $env"
            
            #Clone the keys to edit hashtable during enumeration (note: 'add' or 'remove' operations are not possible)
            foreach ($currentObject in $InputObject[$env].Keys.Clone())
            {
                #Write-Host "------- before Key/Value :  $($currentObject) || $($InputObject[$env][$currentObject])"
                $currentRecord  = $InputObject[$env][$currentObject]
                $count = 0
                #replace all anchor of current entry
                while (([regex]::Matches($currentRecord, "\[\#").count -gt 0) -and ($count -le 10))
                {
                    $start_index = $currentRecord.IndexOf("[#")
                    $end_index = $currentRecord.IndexOf("#]")
                    #full key with [# #]
                    $Balise = $currentRecord.Substring($start_index,($end_index-$start_index)+2)
                    #key without [# #]
                    $BaliseBody = $currentRecord.Substring($start_index+2,($end_index-$start_index)-2)
                    #resolved anchor                    
                    $params = @{
                        Balise = $BaliseBody
                        CurrentEnv = $env
                        CurrentRecord = $currentRecord
                        InputObject = $InputObject
                    }
                    $anchor_value = Get-AnchorValue @params
                    #update current record with resolved anchor
                    $currentRecord = $currentRecord.replace($Balise, $anchor_value)
                    $count++           
                }
                #save result in hashtable
                $InputObject[$env][$currentobject] = $currentRecord
                #Write-Host "------- after Key/Value : $($currentobject) || $($InputObject[$env][$currentobject])"
            }
        }
        return $InputObject
    }
}

<#
.SYNOPSIS
Create github envs and save github vars in appropriate env

.PARAMETER InputObject

.EXAMPLE
Set-GitHubVarsJSON $result
#>
function Set-GitHubVarsJSON {
    [CmdletBinding()]
    param (
        [Parameter()][System.Collections.Hashtable] $InputObject
    )
    process {

        if ($null -eq $InputObject) {
            return $null
        }
        foreach($env in $InputObject.GetEnumerator())
        {
            #Write-Host "**** env ** : $($env.name)"
            if($($env.name) -ne "repository")
            {
                #create github environment
                gh api --method PUT -H "Accept: application/vnd.github+json" repos/$repository/environments/$($env.name)
            }
            foreach($currentobject in $InputObject[$env.name].GetEnumerator())
            {
                #debug
                #Write-Host "***--* name ** : $($currentobject.name)" 
                #Write-Host "***--* value ** : $($currentobject.value)" 
                #Write-Host "***--* key ** : $($currentobject.key)"

                #Save current record to github vars
                if($($env.name) -ne "repository")
                {
                    #set github var in current env
                    gh variable set $($currentobject.name) --env $($env.name) --body $($currentobject.value) --repos "$( $repository )"
                }
                else {
                    #set github var in repository level
                    gh variable set $($currentobject.name) --body $($currentobject.value) --repos "$( $repository )"
                }  
            }
        }
    }
}

##############################################################################
###    MAIN                                                                  #
##############################################################################
# Read json file that contain all github variables                           #
# create github envs, and save all entry in $repository as new github vars   #
##############################################################################
try {
    [System.Collections.Hashtable]$hashtable = [ordered]@{}
    [System.Collections.Hashtable]$result = [ordered]@{}
    
    #Read json file
    $json_var_file = Get-Content $path_to_file | ConvertFrom-Json
    ##root level : 'envs'
    $jsonObjects = $json_var_file.envs
    ##call ConvertTo-Hashtable function
    $hashtable = ConvertTo-Hashtable -InputObject $jsonObjects
    ##resolve all anchors '[#' '#]' in values and save the result in github vars
    $result = Replace-AnchorValueJson -InputObject $hashtable
    #Create GitHub envs and Save into vars
    Set-GitHubVarsJSON -InputObject $result
}
Catch {
    
    throw $_.Exception
} 