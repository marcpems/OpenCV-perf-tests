#Requires -Version 5.1
param(
    [Parameter(Mandatory)][string]$BinLog,
    [Parameter(Mandatory)][string]$Output,
    [Parameter(Mandatory)][string]$MSBuildDirectory
)
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSEdition -ne 'Desktop') {
    throw 'Use Windows PowerShell for the installed .NET Framework MSBuild assemblies.'
}
$BinLog = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BinLog)
$Output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Output)
if (Test-Path $Output) { throw 'Choose a fresh output file.' }
[void][Reflection.Assembly]::LoadFrom("$MSBuildDirectory\Microsoft.Build.Framework.dll")
[void][Reflection.Assembly]::LoadFrom("$MSBuildDirectory\Microsoft.Build.dll")
Add-Type -ReferencedAssemblies @(
    "$MSBuildDirectory\Microsoft.Build.Framework.dll",
    "$MSBuildDirectory\Microsoft.Build.dll",
    'System.Web.Extensions'
) -TypeDefinition @'
using System;
using System.IO;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using Microsoft.Build.Framework;
using Microsoft.Build.Logging;

public static class BinLogEvents
{
    public static void Export(string input, string output)
    {
        var replay = new BinaryLogReplayEventSource();
        var json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        using (var writer = new StreamWriter(output, false, new System.Text.UTF8Encoding(false)))
        {
            replay.AnyEventRaised += (sender, e) =>
            {
                var taskStart = e as TaskStartedEventArgs;
                var taskEnd = e as TaskFinishedEventArgs;
                var project = e as ProjectStartedEventArgs;
                var target = e as TargetStartedEventArgs;
                var context = e.BuildEventContext;
                var row = new Dictionary<string, object> {
                    { "type", e.GetType().Name }, { "timestamp", e.Timestamp.ToString("o") },
                    { "node", context == null ? -1 : context.NodeId },
                    { "project", context == null ? -1 : context.ProjectContextId },
                    { "target", context == null ? -1 : context.TargetId },
                    { "task", context == null ? -1 : context.TaskId },
                    { "message", e.Message }
                };
                if (taskStart != null) row["name"] = taskStart.TaskName;
                if (taskEnd != null) { row["name"] = taskEnd.TaskName; row["succeeded"] = taskEnd.Succeeded; }
                if (project != null) row["project_file"] = project.ProjectFile;
                if (target != null) row["name"] = target.TargetName;
                writer.WriteLine(json.Serialize(row));
            };
            replay.Replay(input);
        }
    }
}
'@
[BinLogEvents]::Export($BinLog, $Output)
Write-Host "Exported local-only MSBuild events: $Output"
