function Connect-AzureBlueprint {
    [CmdletBinding()]
    param (
        [parameter(mandatory=$true)]
        [string]$ManagementGroupName,
        [switch]$Force
    )
    
    begin {
        $Script:AzureContext = Get-AzureRmContext
        if (!$Script:AzureContext){
            Login-AzureRMAccount
            $Script:AzureContext = Get-AzureRmContext
        }
        if (!$Script:AzureContext){
            Write-Warning "Could not connect to Azure"
            Continue
        }
    }
    
    process {
        $ManagementGroups = Get-AzureRmManagementGroup
        if ($ManagementGroups.Name -notcontains $ManagementGroupName){
            if ($Force){
                New-AzureRmManagementGroup -GroupName $ManagementGroupName
            } else {
                Write-Warning "$ManagementGroupName not found. Use the Force switch if you want to create it"
                continue
            }
        }
        $Script:ManagementGroupName = $ManagementGroupName
        $Script:AzureProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
        $Script:AzureProfileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($Script:AzureProfile)
        $Script:BlueprintPrefix = 'https://management.azure.com/providers/Microsoft.Management/managementGroups/{0}/providers/Microsoft.Blueprint/blueprints' -f $Script:ManagementGroupName
        $Script:APIversion = '?api-version=2017-11-11-preview'
        Write-Verbose "Connected to $ManagementGroupName"
    }
    
    end {
    }
}
function Get-AzureBlueprint {
    [CmdletBinding()]
    param (
        [Parameter (ParameterSetName = 'Specific', Mandatory = $True)]
        [string]$Blueprint,
        [Parameter (ParameterSetName = 'All')]
        [Switch]$ListAll,
        [switch]$AsObject
    )
    
    begin {
        if (!$Script:ManagementGroupName){Connect-AzureBlueprint}
        Get-Header
        $ParamHash = @{
            Uri = ''
            Method = 'Get'
            Headers = $Script:Header
            UseBasicParsing = $True
        }
    }
    
    process {
        if ($ListAll){
            $ParamHash.Uri = '{0}{2}' -f $Script:BlueprintPrefix,$Blueprint,$Script:APIversion
        } else {
            $ParamHash.Uri = '{0}/{1}{2}' -f $Script:BlueprintPrefix,$Blueprint,$Script:APIversion
        }
        try {
            $Blueprint = Invoke-WebRequest @ParamHash | Select-Object -ExpandProperty Content
        } catch {
            Write-Warning "$Blueprint not found!"
            continue
        }
    }
    
    end {
        if ($AsObject){
            $Blueprint | ConvertFrom-Json
        } else {
            $Blueprint
        }
    }
}
function Get-AzureBlueprintArtifact {
    [CmdletBinding()]
    param (
        [string]$Blueprint,
        [string[]]$Artifact,
        [switch]$ListAllArtifacts,
        [switch]$AsObject
    )
    
    begin {
        if (!$Script:ManagementGroupName){Connect-AzureBlueprint}
        Get-Header
        $ParamHash = @{
            Uri = ''
            Method = 'GET'
            Headers = $Script:Header
            UseBasicParsing = $True
        }
    }
    
    process {
        $ArtifactJson = @()
        if ($Artifact){
            $ArtifactJson += foreach ($a in $Artifact){
                $ParamHash.Uri = '{0}/{1}/artifacts/{2}{3}' -f $Script:BlueprintPrefix,$Blueprint,$a,$Script:APIversion
                Invoke-WebRequest @ParamHash | Select-Object -ExpandProperty Content
            }
        }
        elseif ($ListAllArtifacts){
            $ParamHash.Uri = '{0}/{1}/artifacts{2}' -f $Script:BlueprintPrefix,$Blueprint,$Script:APIversion
            $ArtifactJson += Invoke-WebRequest @ParamHash| Select-Object -ExpandProperty Content
        }
        else {
            Write-warning "Please prowvide specific artifact names or the -ListAllArtifacts switch"
            continue
        }
    }
    
    end {
        if ($AsObject){
            if ($ListAllArtifacts){
                $ArtifactJson | ConvertFrom-Json | Select-Object -ExpandProperty value
            } else {
                $ArtifactJson | ConvertFrom-Json
            }
        }
        else {$ArtifactJson}
    }
}
function Remove-AzureBlueprint {
    [CmdletBinding()]
    param (
        [string]$Blueprint,
        [string[]]$Artifact,
        [switch]$Recurse
    )
    
    begin {
        $Ids = @()
        if ($Recurse){
            $Ids = Get-AzureBlueprint -Blueprint $Blueprint -AsObject | Select-Object -ExpandProperty Id
        }
        else {
            $Ids += Get-AzureBlueprintArtifact -Blueprint $Blueprint -Artifact $Artifact -AsObject | Select-Object -ExpandProperty Id
        }
    }
    
    process {
        foreach ($Id in $Ids){
            Get-Header
            $ParamHash = @{
                Uri = 'https://management.azure.com{0}{1}' -f $Id,$Script:APIversion
                Method = 'DELETE'
                Headers = $Script:Header
                UseBasicParsing = $True
            }
            $Name = $Id -split '/' | Select-Object -last 1
            try {
                $Req = Invoke-WebRequest @ParamHash
                Write-Verbose "$Name has been deleted"
            } catch {
                Write-Warning "$Name could not be delete"
            }

        }
    }
    
    end {
    }
}
function Set-AzureBlueprint {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [ValidateScript({$_.exists})]
        [System.IO.DirectoryInfo]$BlueprintFolder,
        [switch]$Passthru
    )
    
    begin {
        if (!$Script:ManagementGroupName){Connect-AzureBlueprint}
        If ($JsonFiles = Get-ChildItem $BlueprintFolder.Fullname -Filter *.json){
            Write-Verbose $("Found theee json files",$JsonFiles.name | Out-string)
        } else {
            Write-Warning "No json files found in $BlueprintFolder"
            continue
        }

    }
    
    process {
        $JsonObjects = foreach ($File in $JsonFiles) {
            $FileContent = Get-Content $File.Fullname -Raw
            try {
                $Object = $FileContent | ConvertFrom-Json
                [PSCustomObject]@{
                    Filepath = $File.Fullname
                    Content = $FileContent
                    Kind = $Object.kind
                    Name = $File.BaseName
                    Blueprint = $BlueprintFolder.Name
                }
            } catch {
                Write-Warning "$($File.Fullname) is not a valid JSON"
            }
        }
        Get-Header
        foreach ($JsonObject in $($JsonObjects | Sort-Object kind)){
            $Name = '{0}{1}' -f $JsonObject.Blueprint,$(if ($JsonObject.kind){'/artifacts/{0}' -f $JsonObject.Name} else {''})
            $ParamHash = @{
                Uri = '{0}/{1}{2}' -f $Script:BlueprintPrefix,$Name,$Script:APIversion
                Method = 'PUT'
                Headers = $Script:Header
                Body = $JsonObject.Content
                UseBasicParsing = $True
            }
            Write-Verbose "Uri: $($ParamHash['Uri'])"
            try {
                $Put = Invoke-WebRequest @ParamHash -ErrorVariable Fail
                if ($Passthru){$Put.Content}
            } catch {
                Write-Warning "Could not set $($JsonObject.Name)"
                if ($Fail.message){
                    $Message = try {
                        $fail.message  | ConvertFrom-Json  | Select-Object -ExpandProperty error | Select-Object -ExpandProperty message | Out-String
                    }  catch {
                        $Fail.message
                    }
                }
                else {
                    $Message = $fail
                }
                Write-Warning $Message
            }
        }
    }
    
    end {
    }
}
function Get-Header {
    [CmdletBinding()]
    param (
        
    )
    
    begin {
    }
    
    process {
        $Token = $Script:AzureProfileClient.AcquireAccessToken($Script:AzureContext.Subscription.TenantId)
        Write-Verbose "Accesstoken: $($Token.AccessToken)"
        $Script:Header = @{
            'Content-Type'='application/json'
            'Authorization'='Bearer ' + $Token.AccessToken
        }
    }
    
    end {
    }
}
