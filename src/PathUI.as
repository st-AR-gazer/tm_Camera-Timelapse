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
            if (S_AutoOverwriteCurrent) {
                SaveProgressToCurrentProfile(S_BackupBeforeOverwrite);
            } else {
                SavePartialResume();
            }
            g_LastAutoSaveMs = now;
        }
    }

    void OnEditorExit() {
        if (!S_AutoSaveOnEditorExit || !g_Player.loaded) return;
        if (S_AutoOverwriteCurrent) {
            SaveProgressToCurrentProfile(S_BackupBeforeOverwrite);
        } else {
            SavePartialResume();
        }
    }

    string _DotToUnderscore(const string &in s) {
        string r = s;
        r = r.Replace(".", "_");
        return r;
    }

    string _IsoLocalNoColon() {
        return Time::FormatString("%Y-%m-%dT%H-%M-%S");
    }

    void SavePartialResume() {
        if (!g_Player.loaded) { NotifyWarn("No path loaded to save."); return; }
        if (g_LastLoadedFile.Length == 0) { NotifyWarn("No source file information to save. Load a path first."); return; }

        float t = _NormalizedTimeForSave();

        string baseFull = g_LastLoadedFile;
        string baseFile = Path::GetFileName(baseFull);
        int dotIx = _Text::NthLastIndexOf(baseFile, ".", 1);
        string baseNoExt = dotIx > 0 ? baseFile.SubStr(0, dotIx) : baseFile;

        string shortBase = baseNoExt.StartsWith("path.") ? baseNoExt.SubStr(5) : baseNoExt;

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
        log("SavePartialResume: wrote " + outPath, LogLevel::Info, -1, "PathUI::SavePartialResume");

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

    void SaveProgressToCurrentProfile(bool backupBeforeOverwrite) {
        if (!g_Player.loaded) {
            NotifyWarn("No path loaded to save.");
            return;
        }
        string target = g_LastLoadedFile;
        if (target.Length == 0 || !IO::FileExists(target)) {
            NotifyWarn("Current profile path is unknown. Load a path first.");
            return;
        }

        string resolved = target;
        {
            IO::File f(target, IO::FileMode::Read);
            string blob = f.ReadToEnd(); f.Close();
            auto @root = Json::Parse(blob);
            if (root !is null && root.GetType() == Json::Type::Object) {
                string mode = "";
                ReadString(root, "mode", mode, "");
                auto @resumeObj = root.Get("resume");
                bool isResume = mode.ToLower().StartsWith("resume") || (resumeObj !is null && resumeObj.GetType() == Json::Type::Object);
                if (isResume && resumeObj !is null && resumeObj.GetType() == Json::Type::Object) {
                    string baseFile = "";
                    if (ReadString(resumeObj, "file", baseFile, "")) {
                        if (!IO::FileExists(baseFile)) {
                            string candidate = PathsDir() + "/" + baseFile;
                            if (IO::FileExists(candidate)) baseFile = candidate;
                        }
                        if (IO::FileExists(baseFile)) resolved = baseFile;
                    }
                }
            }
        }

        IO::File f2(resolved, IO::FileMode::Read);
        string src = f2.ReadToEnd(); f2.Close();

        auto @root2 = Json::Parse(src);
        if (root2 is null || root2.GetType() != Json::Type::Object) {
            NotifyError("Failed to parse JSON: " + resolved);
            return;
        }

        root2["mode"] = (g_Player.path.mode == PathMode::Fn ? "fn" : "keyframes");

        auto @md = root2.Get("metadata");
        if (md is null || md.GetType() != Json::Type::Object) {
            Json::Value @newMd = Json::Object();
            newMd["units"] = (g_Player.path.meta.unitsBlocks ? "blocks" : "world");
            newMd["fps"] = g_Player.path.meta.fps;
            newMd["loop"] = g_Player.path.meta.loop;
            root2["metadata"] = newMd;
            @md = root2["metadata"];
        }

        float t = _NormalizedTimeForSave();
        md["start_offset"] = t;

        if (S_SaveRateInProfile) {
            md["speed"] = g_Player.rate;
        }

        md["last_saved_ms"] = int(Time::Now);

        if (backupBeforeOverwrite) {
            string bak = resolved + ".bak." + tostring(Time::Now);
            IO::File fb(bak, IO::FileMode::Write);
            fb.Write(src);
            fb.Close();
        }

        string json = Json::Write(root2);
        IO::File fo(resolved, IO::FileMode::Write);
        fo.Write(json);
        fo.Close();

        NotifyInfo("Saved progress to: " + Path::GetFileName(resolved));
        log("SaveProgressToCurrentProfile: wrote start_offset=" + Text::Format("%.3f", t) + " into " + resolved, LogLevel::Info, -1, "PathUI::SaveProgressToCurrentProfile");
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
                log("UI loaded: " + g_SelectedFile, LogLevel::Info, -1, "PathUI::PathTab");
            } else {
                NotifyError("Failed to load: " + g_SelectedFile);
                log("UI failed to load: " + g_SelectedFile, LogLevel::Error, -1, "PathUI::PathTab");
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
