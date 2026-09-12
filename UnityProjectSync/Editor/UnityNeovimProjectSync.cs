using System;
using System.Reflection;
using UnityEditor;
using UnityEditor.Callbacks;
using UnityEngine;

internal static class UnityNeovimProjectSync
{
    private const string RiderEditorType =
        "Packages.Rider.Editor.RiderScriptEditor, Unity.Rider.Editor";

    [DidReloadScripts]
    private static void SyncProjectFilesAfterScriptReload()
    {
        EditorApplication.delayCall += SyncProjectFiles;
    }

    [MenuItem("Tools/Neovim/Regenerate C# Project Files")]
    private static void SyncProjectFiles()
    {
        try
        {
            var riderType = Type.GetType(RiderEditorType, throwOnError: false);
            var syncSolution = riderType?.GetMethod(
                "SyncSolution",
                BindingFlags.Public | BindingFlags.Static);

            if (syncSolution != null)
            {
                syncSolution.Invoke(null, null);
                return;
            }

            Debug.LogWarning(
                "UnityNeovimProjectSync: Unity's Rider IDE package is required " +
                "to regenerate C# project files while a custom external editor is selected.");
        }
        catch (TargetInvocationException exception)
        {
            Debug.LogException(exception.InnerException ?? exception);
        }
        catch (Exception exception)
        {
            Debug.LogException(exception);
        }
    }
}
