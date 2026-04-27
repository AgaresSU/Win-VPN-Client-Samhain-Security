using System.Diagnostics;

namespace SamhainSecurity.Services;

public static class ProcessRunner
{
    public static async Task<CommandResult> RunProcessAsync(
        string fileName,
        IEnumerable<string> arguments,
        CancellationToken cancellationToken = default)
    {
        using var process = CreateProcess(fileName, arguments);
        process.StartInfo.RedirectStandardOutput = true;
        process.StartInfo.RedirectStandardError = true;

        process.Start();

        var outputTask = process.StandardOutput.ReadToEndAsync(cancellationToken);
        var errorTask = process.StandardError.ReadToEndAsync(cancellationToken);

        try
        {
            await process.WaitForExitAsync(cancellationToken);
        }
        catch (OperationCanceledException)
        {
            TryKill(process);
            throw;
        }

        var output = await outputTask;
        var error = await errorTask;

        return new CommandResult(process.ExitCode, output, error);
    }

    public static Process StartProcess(
        string fileName,
        IEnumerable<string> arguments,
        string? workingDirectory = null)
    {
        var process = CreateProcess(fileName, arguments);
        process.StartInfo.WorkingDirectory = workingDirectory ?? string.Empty;
        process.StartInfo.RedirectStandardOutput = false;
        process.StartInfo.RedirectStandardError = false;
        process.Start();

        return process;
    }

    public static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch
        {
            // The process may have exited between the check and Kill.
        }
    }

    private static Process CreateProcess(string fileName, IEnumerable<string> arguments)
    {
        var process = new Process();
        process.StartInfo.FileName = fileName;
        process.StartInfo.UseShellExecute = false;
        process.StartInfo.CreateNoWindow = true;

        foreach (var argument in arguments)
        {
            process.StartInfo.ArgumentList.Add(argument);
        }

        return process;
    }
}
