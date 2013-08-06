Import-Module CoreFunctions -Force

function Show-InvocationInfo {
    param (
        $Invocation,
        [Switch] $End
    )

    if ($End) {
        Write-LogDebug "</function name='$($Invocation.MyCommand.Name)'>"
    }
    else {
        Write-LogDebug "<function name='$($Invocation.MyCommand.Name)'>"
        Write-LogDebug "<param>"
        foreach ($Parameter in $Invocation.MyCommand.Parameters) {
            foreach ($Key in $Parameter.Keys) {
                $Type = $Parameter[$Key].ParameterType.FullName
                foreach ($Value in $Invocation.BoundParameters[$Key]) {
                    Write-LogDebug "[$Type] $Key = '$Value'"
                }
            }
        }
        Write-LogDebug "</param>"
    }
}

<#
# Usage example for Show-InvocationInfo

function MyFunction {
    param (
        [String] $Value1,
        [String] $Value2,
        [Int] $Int1
    )
    begin {
        Show-InvocationInfo $MyInvocation
    }
    end {
        Show-InvocationInfo $MyInvocation -End
    }
    process {
        # Main code here
    }
}
#>
