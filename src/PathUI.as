namespace PathCam {

    Player g_Player;
    string g_SelectedFile = "";
    array<string> g_Files;
    string g_LastLoadedFile = "";
    uint64 g_LastAutoSaveMs = 0;

    void RefreshFiles() {
        g_Files = ListPathFiles();
        if (g_Files.Length > 0 && (g_SelectedFile.Length == 0 || g_Files.Find(g_SelectedFile) < 0)) {
            g_SelectedFile = g_Files[0];
        }
    }

    void UpdateAutosaveTick() {
        if (S_AutoSaveEvery <= 0.0f) return;
        if (!g_Player.loaded) return;

        uint64 now = Time::Now;
        if (g_LastAutoSaveMs == 0) g_LastAutoSaveMs = now;

        if (now - g_LastAutoSaveMs >= uint64(S_AutoSaveEvery * 1000.0f)) {
            SavePartialResume();
            g_LastAutoSaveMs = now;
        }
    }

    void OnEditorExit() {
        if (!S_AutoSaveOnEditorExit || !g_Player.loaded) return;
        SavePartialResume();
    }

    string _IsoLocalNoColon() {
        return Time::FormatString("%Y-%m-%dT%H-%M-%S");
    }

    string _DotToUnderscore(const string &in s) {
        string r = s;
        r = r.Replace(".", "_");
        return r;
    }

    string _ShortBaseNoExt(const string &in fileName) {
        int dotIx = _Text::NthLastIndexOf(fileName, ".", 1);
        string baseNoExt = dotIx > 0 ? fileName.SubStr(0, dotIx) : fileName;
        if (baseNoExt.ToLower().StartsWith("path.")) baseNoExt = baseNoExt.SubStr(5);
        return baseNoExt;
    }

    string _ResolveOriginalBaseFile() {
        string target = g_LastLoadedFile;
        if (target.Length == 0 || !IO::FileExists(target)) return target;

        IO::File f(target, IO::FileMode::Read);
        string blob = f.ReadToEnd(); f.Close();
        auto @root = Json::Parse(blob);
        if (root is null || root.GetType() != Json::Type::Object) return target;

        string mode = "";
        ReadString(root, "mode", mode, "");
        auto @resumeObj = root.Get("resume");
        bool isResume = mode.ToLower().StartsWith("resume") || (resumeObj !is null && resumeObj.GetType() == Json::Type::Object);
        if (!isResume || resumeObj is null || resumeObj.GetType() != Json::Type::Object) return target;

        string baseFile = "";
        if (!ReadString(resumeObj, "file", baseFile, "")) return target;

        if (!IO::FileExists(baseFile)) {
            string candidate = PathsDir() + "/" + baseFile;
            if (IO::FileExists(candidate)) baseFile = candidate;
        }
        return IO::FileExists(baseFile) ? baseFile : target;
    }

    void SavePartialResume() {
        if (!g_Player.loaded) { NotifyWarn("No path loaded to save."); return; }
        if (g_LastLoadedFile.Length == 0) { NotifyWarn("No source file to save. Load a path first."); return; }

        string baseAbs  = _ResolveOriginalBaseFile();
        string baseFile = Path::GetFileName(baseAbs);
        if (baseFile.Length == 0) { NotifyError("Could not resolve base profile."); return; }

        float t = _NormalizedTimeForSave();

        string shortBase = _ShortBaseNoExt(baseFile);
        string so = _DotToUnderscore(Text::Format("%.3f", t));
        string ts = _IsoLocalNoColon();

        string outName = "path." + shortBase + ".start-" + so + ".resume-" + ts + ".json";
        string outPath = PathsDir() + "/" + outName;

        string json =
            "{\n"
            "  \"version\": 1,\n"
            "  \"name\": \"Resume: " + g_Player.path.name + " @ " + Text::Format('%.3f', t) + "s\",\n"
            "  \"mode\": \"resume\",\n"
            "  \"resume\": {\n"
            "    \"file\": \"" + baseFile + "\",\n"
            "    \"time\": " + Text::Format('%.6f', t) + ",\n"
            "    \"loop\": " + (g_Player.path.meta.loop ? "true" : "false") + ",\n"
            "    \"rate\": " + Text::Format('%.6f', g_Player.rate) + "\n"
            "  }\n"
            "}\n";

        IO::File f(outPath, IO::FileMode::Write);
        f.Write(json);
        f.Close();

        NotifyInfo("Saved resume snapshot: " + outName);
        log("SavePartialResume: wrote " + outPath, LogLevel::Info, 111, "SavePartialResume");
        RefreshFiles();
    }

    float _NormalizedTimeForSave() {
        float dur = g_Player.Duration();
        float t = g_Player.time;
        if (g_Player.path.meta.loop && dur > 0.0) {
            t = t - dur * Math::Floor(t / dur);
            if (t < 0.0) t += dur;
        } else {
            t = Math::Clamp(t, 0.0, dur);
        }
        return t;
    }



    array<string> selectedFiles;

    [SettingsTab name="Camera Path Player" icon="Play" order="2"]
    void PathTab() {
        UI::Text("Paths folder: " + PathsDir());
        if (UI::Button("Refresh file list")) RefreshFiles();
        UI::SameLine();
        if (UI::Button("Copy folder path")) IO::SetClipboard(PathsDir());
        UI::SameLine();

        // Button to open the File Explorer for Paths
        if (UI::Button(Icons::FolderOpen + " Open File Explorer and select JSON for adding")) {
            FileExplorer::fe_Start(
                "Local Files",                       // Unique session ID
                true,                                // _mustReturn: Require selection
                "path",                              // _returnType: "path" or "ElementInfo"
                vec2(1, -1),                         // _minmaxReturnAmount: Min and max selections
                IO::FromUserGameFolder(""),  // _path: Initial folder path
                "",                                  // _searchQuery: Optional search query
                {  },                          // _filters: File type filters
                { "json" }                           // _canOnlyReturn: Allowed types for export
            );
        }

        // Handle Path Selection
        auto pathExplorer = FileExplorer::fe_GetExplorerById("Local Files");
        if (pathExplorer !is null && pathExplorer.exports.IsSelectionComplete()) {
            auto paths = pathExplorer.exports.GetSelectedPaths();
            if (paths !is null) {
                selectedFiles = paths;
                // Additional processing if needed
            }
            pathExplorer.exports.SetSelectionComplete();
        }

        // Display selected file paths
        if (selectedFiles.Length > 0) {
            for (uint i = 0; i < selectedFiles.Length; i++) {
                _IO::File::CopyFileTo(selectedFiles[i], PathsDir() + "/" + Path::GetFileName(selectedFiles[i]), true);
            }
            selectedFiles.RemoveRange(0, selectedFiles.Length);
        }

        UI::Separator();

        if (g_Files.Length == 0) {
            UI::Text("\\$888Put files like 'path.<name>.json' in the folder above.");
        }

        UI::BeginDisabled(g_Files.Length == 0);
        if (UI::BeginCombo("Profile", Path::GetFileName(g_SelectedFile))) {
            for (uint i = 0; i < g_Files.Length; i++) {
                bool sel = (g_Files[i] == g_SelectedFile);
                if (UI::Selectable(g_Files[i], sel)) g_SelectedFile = g_Files[i];
                if (sel) UI::SetItemDefaultFocus();
            }
            UI::EndCombo();
        }

        if (UI::Button("Load")) {
            PathCam::g_Player.LoadFromFile(g_SelectedFile);
            if (PathCam::g_Player.loaded) {
                g_LastLoadedFile = g_SelectedFile;
                NotifyInfo("Loaded: " + PathCam::g_Player.path.name + " (" + Text::Format("%.2f", PathCam::g_Player.Duration()) + "s)");
                log("UI loaded: " + g_SelectedFile, LogLevel::Info, 193, "PathTab");
            } else {
                NotifyError("Failed to load: " + g_SelectedFile);
                log("UI failed to load: " + g_SelectedFile, LogLevel::Error, 196, "PathTab");
            }
        }

        UI::EndDisabled();

        UI::Separator();

        UI::BeginDisabled(!g_Player.loaded);
        if (!g_Player.playing) {
            if (UI::Button(Icons::Play + " Play")) g_Player.Play();
        } else {
            if (UI::Button(Icons::Pause + " Pause")) g_Player.Pause();
        }
        UI::SameLine();
        if (UI::Button(Icons::Stop + " Stop")) g_Player.Stop();

        UI::SameLine();
        if (UI::Button(Icons::FloppyO + " Save resume snapshot")) SavePartialResume();

        UI::SameLine();
        bool newSnap = UI::Checkbox("Snap to FPS frames", g_Player.snapToFps);
        if (newSnap != g_Player.snapToFps) {
            g_Player.snapToFps = newSnap;
            S_DefaultSnapToFps = newSnap;
        }

        float dur = g_Player.Duration();

        float tOld = g_Player.time;
        float tNew = UI::SliderFloat("Time (s)", tOld, 0.0, Math::Max(1.0, dur));
        if (tNew != tOld) g_Player.Seek(tNew);

        float rateOld = g_Player.rate;
        float rateNew = UI::SliderFloat("Rate", rateOld, S_RateMin, S_RateMax);
        if (rateNew != rateOld) {
            g_Player.rate = rateNew;
            S_DefaultRate = rateNew;
        }

        if (g_Player.loaded) {
            UI::Text("Path: " + g_Player.path.name);
            UI::Text("Mode: " + (g_Player.path.mode == PathMode::Keyframes ? "keyframes" : "fn"));
            UI::Text("FPS: " + Text::Format("%.2f", g_Player.path.meta.fps) + "  Loop: " + (g_Player.path.meta.loop ? "Yes" : "No"));
            UI::Text("Duration: " + Text::Format("%.2f s", dur));
        }
        UI::EndDisabled();
    }

}
