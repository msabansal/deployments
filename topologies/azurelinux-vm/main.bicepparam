using 'main.bicep'

param namePrefix = 'azlinux'
param vnetAddressPrefix = '10.40.0.0/16'
param subnetAddressPrefix = '10.40.0.0/24'
param adminUsername = 'azureuser'
param vmSize = 'Standard_D4d_v5'
param osDiskStorageAccountType = 'StandardSSD_LRS'
param diskControllerType = 'SCSI'
param imageVersion = 'latest'

// Supplied at deploy time by deploy.ps1.
param location = ''
param adminPublicKey = ''
