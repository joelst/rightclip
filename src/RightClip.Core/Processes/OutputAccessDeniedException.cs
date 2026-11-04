namespace RightClip.Core.Processes;

public sealed class OutputAccessDeniedException : IOException
{
    public OutputAccessDeniedException(string outputPath, Exception innerException)
        : base($"Windows denied saving '{outputPath}'. Check the folder's write permissions. " +
            "If Controlled folder access blocked the write, allow RightClip.exe and its bundled ffmpeg.exe " +
            "in Windows Security's ransomware protection settings, then retry. The original file was not changed.",
            innerException)
    {
    }
}
