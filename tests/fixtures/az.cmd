@echo off
if "%~1 %~2"=="account show" (
    echo {"id":"00000000-0000-0000-0000-000000000000","name":"Synthetic subscription"}
    exit /b 0
)
if "%~1 %~2"=="account set" exit /b 0
echo WARNING: synthetic CLI warning 1>&2
if "%~1"=="rest" goto rest
echo []
exit /b 0

:rest
if "%~3"=="post" goto cost
if "%COLLECTION_TEST_MODE%"=="disk-failure" (
    echo ERROR: synthetic disk permission denied 1>&2
    exit /b 1
)
if "%~5"=="https://management.azure.com/synthetic-page-2" (
    echo {"value":[{"name":"contoso-disk-2","diskState":"Attached"}]}
) else (
    echo {"value":[{"name":"contoso-disk-1","diskState":"Unattached"}],"nextLink":"https://management.azure.com/synthetic-page-2"}
)
exit /b 0

:cost
if "%COLLECTION_TEST_MODE%"=="cost-failure" (
    echo ERROR: synthetic AuthorizationFailed 1>&2
    exit /b 1
)
if "%COLLECTION_TEST_MODE%"=="empty-cost" (
    echo {"properties":{"rows":[]}}
    exit /b 0
)
if "%COLLECTION_TEST_MODE%"=="invalid-cost" (
    echo not JSON
    exit /b 0
)
if "%COLLECTION_TEST_MODE%"=="missing-rows" (
    echo {"properties":{}}
    exit /b 0
)
echo {"properties":{"rows":[[12.5,"Synthetic service","USD"],[0,"Other service","USD"]]}}
exit /b 0
