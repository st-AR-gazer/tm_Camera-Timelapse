// Fun Utils I use from time to time

namespace _Text {
    int NthLastIndexOf(const string &in str, const string &in value, int n) {
        int index = -1;
        for (int i = str.Length - 1; i >= 0; --i) {
            if (str.SubStr(i, value.Length) == value) {
                if (n == 1) {
                    index = i;
                    break;
                }
                --n;
            }
        }
        return index;
    }
}

namespace _IO {
    namespace Directory {
        bool IsDirectory(const string &in path) {
            if (path.EndsWith("/") || path.EndsWith("\\")) return true;
            return false;
        }
    }

    namespace File {
        void WriteFile(string _path, const string &in content, bool verbose = false) {
            string path = _path;
            if (verbose) log("Writing to file: " + path, LogLevel::Info, 30, "WriteFile");

            if (path.EndsWith("/") || path.EndsWith("\\")) { log("Invalid file path: " + path, LogLevel::Error, 32, "WriteFile"); return; }

            if (!IO::FolderExists(Path::GetDirectoryName(path))) { IO::CreateFolder(Path::GetDirectoryName(path), true); }

            IO::File file;
            file.Open(path, IO::FileMode::Write);
            file.Write(content);
            file.Close();
        }

        // Read from file
        string ReadFileToEnd(const string &in path, bool verbose = false) {
            if (verbose) log("Reading file: " + path, LogLevel::Info, 44, "ReadFileToEnd");
            if (!IO::FileExists(path)) { log("File does not exist: " + path, LogLevel::Error, 45, "ReadFileToEnd"); return ""; }

            IO::File file(path, IO::FileMode::Read);
            string content = file.ReadToEnd();
            file.Close();
            return content;
        }
        
        string ReadSourceFileToEnd(const string &in path, bool verbose = false) {
            if (!IO::FileExists(path)) { log("File does not exist: " + path, LogLevel::Error, 54, "ReadSourceFileToEnd"); return ""; }

            IO::FileSource f(path);
            string content = f.ReadToEnd();
            return content;
        }

        // Copy file
        void CopyFileTo(const string &in source, const string &in destination, bool overwrite = false, bool verbose = false) {
            if (!IO::FileExists(source)) { if (verbose) log("Source file does not exist: " + source, LogLevel::Error, 63, "CopyFileTo"); return; }
            if (IO::FileExists(destination) && !overwrite) { if (verbose) log("Destination file already exists: " + destination, LogLevel::Error, 64, "CopyFileTo"); return; }

            string content = ReadFileToEnd(source, verbose);
            WriteFile(destination, content, verbose);
        }
    }
}
