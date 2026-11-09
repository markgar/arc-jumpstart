param([Parameter(Mandatory)][string]$RunId)
$ErrorActionPreference = 'Stop'
# PROGRESS_PROOF_FUNCTIONS
Write-Output (New-LabProofFrame -RunId $RunId -Sequence 1)
Start-Sleep -Seconds 40
Write-Output ('PROOF_NOISE_' * 1200)
Write-Output (New-LabProofFrame -RunId $RunId -Sequence 2)
Start-Sleep -Seconds 40
Write-Output (New-LabProofFrame -RunId $RunId -Sequence 3)
Start-Sleep -Seconds 10
