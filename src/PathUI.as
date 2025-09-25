namespace PathCam {

    Player g_Player;
    string g_SelectedFile = "";
    array<string> g_Files;

    void RefreshFiles() {
        g_Files = ListPathFiles();
        if (g_Files.Length > 0 && (g_SelectedFile.Length == 0 || g_Files.Find(g_SelectedFile) < 0)) {
            g_SelectedFile = g_Files[0];
        }
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
        if (UI::BeginCombo("Profile", g_SelectedFile)) {
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
                NotifyInfo("Loaded: " + PathCam::g_Player.path.name + " (" + Text::Format("%.2f", PathCam::g_Player.Duration()) + "s)");
                log("UI loaded: " + g_SelectedFile, LogLevel::Info, 77, "PathTab");
            } else {
                NotifyError("Failed to load: " + g_SelectedFile);
                log("UI failed to load: " + g_SelectedFile, LogLevel::Error, 80, "PathTab");
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
        UI::Checkbox("Snap to FPS frames", g_Player.snapToFps);

        float dur = g_Player.Duration();

        float tOld = g_Player.time;
        float tNew = UI::SliderFloat("Time (s)", tOld, 0.0, Math::Max(1.0, dur));
        if (tNew != tOld) g_Player.Seek(tNew);

        float rateOld = g_Player.rate;
        float rateNew = UI::SliderFloat("Rate", rateOld, 0.1, 10.0);
        if (rateNew != rateOld) g_Player.rate = rateNew;

        if (g_Player.loaded) {
            UI::Text("Path: " + g_Player.path.name);
            UI::Text("Mode: " + (g_Player.path.mode == PathMode::Keyframes ? "keyframes" : "fn"));
            UI::Text("FPS: " + Text::Format("%.2f", g_Player.path.meta.fps) + "  Loop: " + (g_Player.path.meta.loop ? "Yes" : "No"));
            UI::Text("Duration: " + Text::Format("%.2f s", dur));
        }
        UI::EndDisabled();
    }

}
