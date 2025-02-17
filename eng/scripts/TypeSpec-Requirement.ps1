[CmdletBinding()]
param (
)
Set-StrictMode -Version 3

. $PSScriptRoot/ChangedFiles-Functions.ps1
. $PSScriptRoot/Logging-Functions.ps1

$repoPath = Resolve-Path "$PSScriptRoot/../.."
$pathsWithErrors = @()

$filesToCheck = @(Get-ChangedSwaggerFiles).Where({
  ($_ -notmatch "/(examples|scenarios|restler|common|common-types)/") -and
  ($_ -match "specification/[^/]+/(data-plane|resource-manager).*?/(preview|stable)/[^/]+/[^/]+\.json$")
})

if (!$filesToCheck) {
  LogInfo "No OpenAPI files found to check"
}
else {
  # Cache responses to GitHub web requests, for efficiency and to prevent rate limiting
  $responseCache = @{}

  # - Forward slashes on both Linux and Windows
  # - May be nested 4 or 5 levels deep, perhaps even deeper
  # - Examples
  #   - specification/foo/data-plane/Foo/stable/2023-01-01/Foo.json
  #   - specification/foo/data-plane/Foo/bar/stable/2023-01-01/Foo.json
  #   - specification/foo/resource-manager/Microsoft.Foo/stable/2023-01-01/Foo.json
  foreach ($file in $filesToCheck) {
    LogInfo "Checking $file"

    $jsonContent = Get-Content (Join-Path $repoPath $file) | ConvertFrom-Json -AsHashtable

    if ($null -ne ${jsonContent}?["info"]?["x-typespec-generated"]) {
      LogInfo "  OpenAPI was generated from TypeSpec (contains '/info/x-typespec-generated')"
      # Skip further checks, since spec is already using TypeSpec
      continue
    }
    else {
      LogInfo "  OpenAPI was not generated from TypeSpec (missing '/info/x-typespec-generated')"
    }

    # Extract path between "specification/" and "/(preview|stable)"
    if ($file -match "specification/(?<servicePath>[^/]+/(data-plane|resource-manager).*?)/(preview|stable)/[^/]+/[^/]+\.json$") {
      $servicePath = $Matches["servicePath"]
    }
    else {
      LogError "  Path to OpenAPI did not match expected regex.  Unable to extract service path."
      LogJobFailure
      exit 1
    }

    $urlToStableFolder = "https://github.com/Azure/azure-rest-api-specs/tree/main/specification/$servicePath/stable"

    # Avoid conflict with pipeline secret
    $logUrlToStableFolder = $urlToStableFolder -replace '^https://',''

    LogInfo "  Checking $logUrlToStableFolder"

    $responseStatus = $responseCache[$urlToStableFolder];
    if ($null -ne $responseStatus) {
      LogInfo "    Found in cache"
    }
    else {
      LogInfo "    Not found in cache, making web request"
      try {
        $response = Invoke-WebRequest -Uri $urlToStableFolder -Method Head -SkipHttpErrorCheck
        $responseStatus = $response.StatusCode
        $responseCache[$urlToStableFolder] = $responseStatus
      }
      catch {
        LogError "  Exception making web request to ${logUrlToStableFolder}: $_"
        LogJobFailure
        exit 1
      }
    }

    LogInfo "    Status: $responseStatus"

    if ($responseStatus -eq 200) {
      LogInfo "  Branch 'main' contains path '$servicePath/stable', so spec already exists and is not required to use TypeSpec"
    }
    elseif ($response.StatusCode -eq 404) {
      LogInfo "  Branch 'main' does not contain path '$servicePath/stable', so spec is new and must use TypeSpec"
      $pathsWithErrors += $file
    }
    else {
      LogError "Unexpected response from ${logUrlToStableFolder}: ${response.StatusCode}"
      LogJobFailure
      exit 1
    }
  }
}

if ($pathsWithErrors.Count -gt 0)
{
  # DevOps only adds the first 4 errors to the github checks list so lets always add the generic one first
  # and then as many of the individual ones as can be found afterwards
  LogError "New specs must use TypeSpec.  For more detailed docs see https://aka.ms/azsdk/typespec"
  LogJobFailure

  foreach ($path in $pathsWithErrors)
  {
    LogErrorForFile $path "OpenAPI was not generated from TypeSpec, and spec appears to be new"
  }
  exit 1
}

exit 0
