namespace PathCam {

    string PathsDir() {
        string p = IO::FromStorageFolder("paths");
        if (!IO::FolderExists(p)) IO::CreateFolder(p);
        return p;
    }

    array<string> ListPathFiles() {
        string dir = PathsDir();
        auto entries = IO::IndexFolder(dir, false);
        array<string> files;
        for (uint i = 0; i < entries.Length; i++) {
            string fullPath = entries[i];
            string fileOnly = Path::GetFileName(fullPath);
            if (fileOnly.EndsWith(".json") && fileOnly.StartsWith("path.")) {
                files.InsertLast(fullPath);
            }
        }
        files.SortAsc();
        return files;
    }


    vec3 CoordToPosBlocks(const vec3 &in bc) {
        return vec3(bc.x * 32.0, (int(bc.y) - 8) * 8.0, bc.z * 32.0);
    }

    bool ReadFloat(const Json::Value@ v, const string &in key, float &out dst, float def=0.0) {
        dst = def;
        if (v is null) return false;
        auto @x = v.Get(key);
        if (x is null || x.GetType() == Json::Type::Null) return false;

        if (x.GetType() == Json::Type::String) {
            string s = string(x);
            float val = Text::ParseFloat(s);
            dst = val;
            return true;
        }

        dst = float(x);
        return true;
    }

    bool ReadBool(const Json::Value@ v, const string &in key, bool &out dst, bool def=false) {
        dst = def;
        if (v is null) return false;
        auto @x = v.Get(key);
        if (x is null || x.GetType() == Json::Type::Null) return false;

        Json::Type t = x.GetType();

        if (t == Json::Type::Boolean) { dst = bool(x); return true; }

        if (t == Json::Type::Number) { float val = float(x);  dst = (val != 0.0f); return true; }

        if (t == Json::Type::String) {
            string s = string(x);
            s = s.Trim().ToLower();
            if (s == "true" || s == "1" || s == "yes" || s == "y" || s == "on")  { dst = true;  return true; }
            if (s == "false"|| s == "0" || s == "no"  || s == "n" || s == "off") { dst = false; return true; }
            return false;
        }

        return false;
    }



    bool ReadString(const Json::Value@ v, const string &in key, string &out dst, const string &in def="") {
        if (v is null) { dst = def; return false; }
        auto @x = v.Get(key);
        if (x is null || x.GetType() == Json::Type::Null) { dst = def; return false; }
        dst = string(x);
        return true;
    }

    bool ReadVec3(const Json::Value@ v, const string &in key, vec3 &out dst) {
        if (v is null) return false;
        auto @a = v.Get(key);
        if (a is null || a.GetType() != Json::Type::Array || a.Length < 3) return false;
        dst = vec3(float(a[0]), float(a[1]), float(a[2]));
        return true;
    }

    void ParseMetadata(const Json::Value@ md, PathMetadata &out meta) {
        if (md is null) return;
        ReadFloat(md, "fps", meta.fps, meta.fps);
        ReadFloat(md, "duration", meta.duration, meta.duration);
        ReadBool(md, "loop", meta.loop, meta.loop);
        ReadFloat(md, "speed", meta.speed, meta.speed);
        string interp = "catmullrom";
        ReadString(md, "interpolation", interp, interp);
        meta.interp = interp.ToLower().StartsWith("lin") ? InterpMode::Linear : InterpMode::CatmullRom;
        string units = "world";
        ReadString(md, "units", units, units);
        meta.unitsBlocks = units.ToLower().StartsWith("block");
    }

    vec3 AsWorld(const PathMetadata &in meta, const vec3 &in v) {
        return meta.unitsBlocks ? CoordToPosBlocks(v) : v;
    }

    void SortKeysByTime(array<CamKey> &inout ks) {
        for (uint i = 1; i < ks.Length; i++) {
            CamKey k = ks[i];
            int j = i - 1;
            while (j >= 0 && ks[uint(j)].t > k.t) {
                ks[uint(j + 1)] = ks[uint(j)];
                j--;
            }
            ks[uint(j + 1)] = k;
        }
    }

    bool LoadFloatCurve(const Json::Value@ parent, const string &in key, FloatCurve &out curve) {
        curve.keys.RemoveRange(0, curve.keys.Length);
        if (parent is null) return false;
        auto @arr = parent.Get(key);
        if (arr is null || arr.GetType() != Json::Type::Array) return false;

        for (uint i = 0; i < arr.Length; i++) {
            auto @e = arr[i];
            if (e is null) continue;

            FloatKey k;
            if (e.GetType() == Json::Type::Array && e.Length >= 2) {
                k.u = float(e[0]);
                k.v = float(e[1]);
            } else if (e.GetType() == Json::Type::Object) {
                bool haveU = ReadFloat(e, "u", k.u, -1.0f);
                if (!haveU) {
                    log("LoadFloatCurve: object key without 'u' not supported; use [u,value] pairs.", LogLevel::Warn, 153, "LoadFloatCurve");
                    continue;
                }
                ReadFloat(e, "value", k.v, 0.0f);
            } else {
                continue;
            }

            if (Math::IsInf(k.u)) k.u = 0.0f;
            curve.keys.InsertLast(k);
        }

        if (curve.keys.Length == 0) return false;
        curve.SortByU();
        return true;
    }

    bool LoadPolylinePoints(const Json::Value@ parent, const string &in key, const PathMetadata &in meta, array<vec3> &out outPts) {
        outPts.RemoveRange(0, outPts.Length);
        if (parent is null) return false;
        auto @arr = parent.Get(key);
        if (arr is null || arr.GetType() != Json::Type::Array) return false;
        for (uint i = 0; i < arr.Length; i++) {
            auto @p = arr[i];
            if (p is null || p.GetType() != Json::Type::Array || p.Length < 3) continue;
            vec3 v = vec3(float(p[0]), float(p[1]), float(p[2]));
            v = AsWorld(meta, v);
            outPts.InsertLast(v);
        }
        return outPts.Length >= 2;
    }

    bool LoadKeyframes(const Json::Value@ root, CameraPath &out path) {
        auto @arr = root.Get("keyframes");
        if (arr is null || arr.GetType() != Json::Type::Array) return false;
        path.keys.RemoveRange(0, path.keys.Length);

        for (uint i = 0; i < arr.Length; i++) {
            auto @kf = arr[i];
            CamKey k;
            ReadFloat(kf, "t", k.t, 0.0);

            vec3 tgt;
            if (ReadVec3(kf, "target", tgt)) {
                k.target = AsWorld(path.meta, tgt);
            }

            ReadFloat(kf, "dist", k.dist, 200.0);

            auto @ang = kf.Get("angles_deg");
            if (ang !is null && ang.GetType() == Json::Type::Array && ang.Length >= 2) {
                k.h = float(ang[0]) * DEG2RAD;
                k.v = float(ang[1]) * DEG2RAD;
            } else {
                k.h = 0.0; k.v = 0.0;
            }

            path.keys.InsertLast(k);
        }

        SortKeysByTime(path.keys);

        if (path.meta.duration <= 0.0 && path.keys.Length > 0) {
            path.meta.duration = path.keys[path.keys.Length - 1].t;
        }
        return path.keys.Length > 0;
    }

    void LoadFn(const Json::Value@ root, CameraPath &out path) {
        auto @f = root.Get("fn");
        if (f is null || f.GetType() != Json::Type::Object) return;
        ReadString(f, "name", path.fnName, path.fnName);
        string n = path.fnName.ToLower();

        if (n == "orbital_circle") {
            ReadVec3(f, "center", path.fnCircle.center);
            path.fnCircle.center = AsWorld(path.meta, path.fnCircle.center);
            ReadFloat(f, "radius", path.fnCircle.radius, path.fnCircle.radius);
            ReadFloat(f, "v_deg", path.fnCircle.vDeg, path.fnCircle.vDeg);
            ReadFloat(f, "deg_per_sec", path.fnCircle.degPerSec, path.fnCircle.degPerSec);
            ReadFloat(f, "start_deg", path.fnCircle.startDeg, path.fnCircle.startDeg);
            ReadBool(f, "cw", path.fnCircle.cw, path.fnCircle.cw);

        } else if (n == "orbital_helix") {
            ReadVec3(f, "center", path.fnHelix.center);
            path.fnHelix.center = AsWorld(path.meta, path.fnHelix.center);
            ReadFloat(f, "radius", path.fnHelix.radius, path.fnHelix.radius);
            ReadFloat(f, "v_start_deg", path.fnHelix.vStartDeg, path.fnHelix.vStartDeg);
            ReadFloat(f, "v_end_deg", path.fnHelix.vEndDeg, path.fnHelix.vEndDeg);
            ReadFloat(f, "deg_per_sec", path.fnHelix.degPerSec, path.fnHelix.degPerSec);
            ReadFloat(f, "start_deg", path.fnHelix.startDeg, path.fnHelix.startDeg);
            ReadBool(f,  "cw", path.fnHelix.cw, path.fnHelix.cw);

            vec3 cEnd;
            if (ReadVec3(f, "center_end", cEnd)) {
                path.fnHelix.centerEnd = AsWorld(path.meta, cEnd);
                path.fnHelix.hasCenterEnd = true;
            }
            ReadFloat(f, "center_lerp_pow", path.fnHelix.centerLerpPow, path.fnHelix.centerLerpPow);

        } else if (n == "target_polyline") {
            LoadPolylinePoints(f, "points", path.meta, path.fnPolyline.pts);
            ReadBool(f, "closed", path.fnPolyline.closed, path.fnPolyline.closed);
            ReadFloat(f, "speed", path.fnPolyline.speed, path.fnPolyline.speed);
            ReadFloat(f, "dist", path.fnPolyline.dist, path.fnPolyline.dist);
            ReadFloat(f, "look_ahead", path.fnPolyline.lookAhead, path.fnPolyline.lookAhead);
            ReadFloat(f, "height_offset", path.fnPolyline.heightOffset, path.fnPolyline.heightOffset);
            string interp = "catmullrom";
            ReadString(f, "interpolation", interp, interp);
            path.fnPolyline.interp = interp.ToLower().StartsWith("lin") ? InterpMode::Linear : InterpMode::CatmullRom;

            LoadFloatCurve(f, "height_offset_keys", path.fnPolyline.heightCurve);
            LoadFloatCurve(f, "dist_keys", path.fnPolyline.distCurve);
            LoadFloatCurve(f, "look_ahead_keys", path.fnPolyline.lookAheadCurve);

            path.fnPolyline.RebuildLengths();

            if (path.meta.duration <= 0.0f && path.fnPolyline.speed > 0.0f && path.fnPolyline.totalLen > 0.0f) {
                path.meta.duration = path.fnPolyline.totalLen / path.fnPolyline.speed;
                log("LoadPath: derived duration from polyline length: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, 270, "LoadFn");
            }

        } else if (n == "vertical_ascent") {
            ReadVec3(f, "center", path.fnAscent.center);
            path.fnAscent.center = AsWorld(path.meta, path.fnAscent.center);

            ReadFloat(f, "dist_start", path.fnAscent.distStart, path.fnAscent.distStart);
            ReadFloat(f, "dist_end",   path.fnAscent.distEnd,   path.fnAscent.distEnd);
            ReadFloat(f, "dist_rate",  path.fnAscent.distRate,  path.fnAscent.distRate);
            ReadFloat(f, "v_deg",      path.fnAscent.vDeg,      path.fnAscent.vDeg);
            ReadFloat(f, "start_deg",  path.fnAscent.startDeg,  path.fnAscent.startDeg);
            ReadFloat(f, "deg_per_sec",path.fnAscent.degPerSec, path.fnAscent.degPerSec);
            ReadBool (f, "cw",         path.fnAscent.cw,        path.fnAscent.cw);


            if (path.meta.duration <= 0.0) {
                float fnDur;
                if (ReadFloat(f, "duration", fnDur, -1.0) && fnDur > 0.0) {
                    path.meta.duration = fnDur;
                    log("LoadPath: used fn.duration=" + Text::Format("%.3f", fnDur) + "s", LogLevel::Info, -1, "PathCam::LoadFn");
                }
            }

            float delta = Math::Abs(path.fnAscent.distEnd - path.fnAscent.distStart);
            if (path.fnAscent.distRate > 0.0 && delta > 0.0) {
                path.meta.duration = delta / path.fnAscent.distRate;
                log("LoadPath: derived duration for vertical_ascent from dist_rate: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, -1, "PathCam::LoadPath");
            } else if (Math::Abs(path.fnAscent.degPerSec) > 0.0) {
                path.meta.duration = 360.0 / Math::Abs(path.fnAscent.degPerSec);
                log("LoadPath: derived duration for vertical_ascent from deg_per_sec: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, -1, "PathCam::LoadPath");
            }

        } else if (n == "moving_orbit") {
            LoadPolylinePoints(f, "center_points", path.meta, path.fnMovingOrbit.center.pts);
            bool tmpClosed;
            if (ReadBool(f, "center_closed", tmpClosed, path.fnMovingOrbit.center.closed)) {
                path.fnMovingOrbit.center.closed = tmpClosed;
            } else {
                ReadBool(f, "closed", path.fnMovingOrbit.center.closed, path.fnMovingOrbit.center.closed);
            }
            ReadFloat(f, "center_speed", path.fnMovingOrbit.center.speed, path.fnMovingOrbit.center.speed);
            path.fnMovingOrbit.center.RebuildLengths();

            ReadFloat(f, "radius", path.fnMovingOrbit.radius, path.fnMovingOrbit.radius);
            ReadFloat(f, "v_deg", path.fnMovingOrbit.vDeg, path.fnMovingOrbit.vDeg);
            ReadFloat(f, "deg_per_sec", path.fnMovingOrbit.degPerSec, path.fnMovingOrbit.degPerSec);
            ReadFloat(f, "start_deg", path.fnMovingOrbit.startDeg, path.fnMovingOrbit.startDeg);
            ReadBool(f, "cw", path.fnMovingOrbit.cw, path.fnMovingOrbit.cw);

            LoadFloatCurve(f, "radius_keys", path.fnMovingOrbit.radiusCurve);
            LoadFloatCurve(f, "v_deg_keys", path.fnMovingOrbit.vDegCurve);

            if (path.meta.duration <= 0.0f) {
                if (path.fnMovingOrbit.center.speed > 0.0f && path.fnMovingOrbit.center.totalLen > 0.0f) {
                    path.meta.duration = path.fnMovingOrbit.center.totalLen / path.fnMovingOrbit.center.speed;
                    log("LoadPath: derived duration from moving_orbit center length: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, 302, "LoadFn");
                } else {
                    float dps = Math::Abs(path.fnMovingOrbit.degPerSec);
                    if (dps > 0.0f) {
                        path.meta.duration = 360.0f / dps;
                        log("LoadPath: derived duration from moving_orbit deg_per_sec: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, 307, "LoadFn");
                    }
                }
            }
        }
    }

    bool LoadPath(const string &in fileOrRel, CameraPath &out path) {
        string abs = fileOrRel;
        if (!IO::FileExists(abs)) {
            string candidate = PathsDir() + "/" + fileOrRel;
            if (IO::FileExists(candidate)) abs = candidate;
        }

        if (!IO::FileExists(abs)) {
            log("LoadPath: not found '" + fileOrRel + "' (also looked in " + PathsDir() + ")", LogLevel::Error, 323, "LoadPath");
            return false;
        }

        log("LoadPath: opening " + abs, LogLevel::Info, 327, "LoadPath");

        IO::File f(abs, IO::FileMode::Read);
        string blob = f.ReadToEnd();
        f.Close();

        if (blob.Length == 0) {
            log("LoadPath: empty file: " + abs, LogLevel::Error, 334, "LoadPath");
            return false;
        }

        auto @root = Json::Parse(blob);
        if (root is null || root.GetType() != Json::Type::Object) {
            log("LoadPath: JSON parse failed or root is not an object: " + abs, LogLevel::Error, 340, "LoadPath");
            return false;
        }

        auto @ver = root.Get("version");
        if (ver !is null && ver.GetType() != Json::Type::Null) path.version = int(ver);

        ReadString(root, "name", path.name, "");

        string mode = "keyframes";
        ReadString(root, "mode", mode, mode);
        path.mode = mode.ToLower().StartsWith("fn") ? PathMode::Fn : PathMode::Keyframes;

        auto @md = root.Get("metadata");
        ParseMetadata(md, path.meta);

        if (path.meta.duration <= 0.0) {
            float topDur;
            if (ReadFloat(root, "duration", topDur, -1.0) && topDur > 0.0) {
                path.meta.duration = topDur;
                log("LoadPath: using top-level duration=" + Text::Format("%.3f", topDur), LogLevel::Info, 364, "LoadPath");
            }
        }

        bool ok = false;
        if (path.mode == PathMode::Keyframes) {
            ok = LoadKeyframes(root, path);
            if (!ok) {
                log("LoadPath: no/invalid keyframes in " + abs, LogLevel::Error, 374, "LoadPath");
                return false;
            }

            if (path.meta.duration <= 0.0 && path.keys.Length > 0) {
                path.meta.duration = path.keys[path.keys.Length - 1].t;
                log("LoadPath: inferred duration from last keyframe: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, 381, "LoadPath");
            }

            if (path.keys.Length == 0) {
                log("LoadPath: keyframes mode but keys.Length == 0", LogLevel::Error, 386, "LoadPath");
                return false;
            }

            ok = true;
        } else {
            LoadFn(root, path);

            if (path.meta.duration <= 0.0) {
                auto @fnObj = root.Get("fn");
                float fnDur;
                if (ReadFloat(fnObj, "duration", fnDur, -1.0) && fnDur > 0.0) {
                    path.meta.duration = fnDur;
                    log("LoadPath: used fn.duration=" + Text::Format("%.3f", fnDur) + "s", LogLevel::Info, 401, "LoadPath");
                }
            }

            if (path.meta.duration <= 0.0) {
                string fn = path.fnName.ToLower();
                if (fn == "orbital_circle") {
                    float dps = Math::Abs(path.fnCircle.degPerSec);
                    if (dps > 0.0) {
                        path.meta.duration = 360.0 / dps;
                        log("LoadPath: derived duration for orbital_circle: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, 412, "LoadPath");
                    }
                } else if (fn == "orbital_helix") {
                    float dps = Math::Abs(path.fnHelix.degPerSec);
                    if (dps > 0.0) {
                        path.meta.duration = 360.0 / dps;
                        log("LoadPath: derived duration for orbital_helix: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, 418, "LoadPath");
                    }
                } else if (fn == "target_polyline") {
                    if (path.fnPolyline.totalLen > 0.0 && path.fnPolyline.speed > 0.0) {
                        path.meta.duration = path.fnPolyline.totalLen / path.fnPolyline.speed;
                        log("LoadPath: derived duration from polyline length: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, 423, "LoadPath");
                    }
                }
            }

            if (path.fnName.Length == 0) { log("LoadPath: fn-mode but no fn.name specified", LogLevel::Error, 430, "LoadPath"); return false; }
            if (path.meta.duration <= 0.0) { log("LoadPath: fn-mode requires metadata.duration>0 (or derivable), currently duration=" + Text::Format("%.3f", path.meta.duration), LogLevel::Error, 434, "LoadPath"); return false; }

            ok = true;
        }

        bool loopVal = path.meta.loop;
        bool haveLoop = false;

        auto @mdObj   = root.Get("metadata");
        auto @fnObj   = root.Get("fn");
        bool tmpLoop;

        if (ReadBool(mdObj, "loop", tmpLoop, loopVal) || ReadBool(mdObj, "Loop", tmpLoop, loopVal)) {
            loopVal = tmpLoop;
            haveLoop = true;
        }

        if (!haveLoop && (ReadBool(root, "loop", tmpLoop, loopVal) || ReadBool(root, "Loop", tmpLoop, loopVal))) {
            loopVal = tmpLoop;
            haveLoop = true;
        }

        if (!haveLoop && (ReadBool(fnObj, "loop", tmpLoop, loopVal) || ReadBool(fnObj, "Loop", tmpLoop, loopVal))) {
            loopVal = tmpLoop;
            haveLoop = true;
        }

        path.meta.loop = loopVal;
        log("LoadPath: loop=" + (path.meta.loop ? "true" : "false") + (haveLoop ? "" : " (default)"), LogLevel::Info, 465, "LoadPath");

        if (path.name.Length == 0) {
            string fileOnly = Path::GetFileName(abs);
            int dotIx = _Text::NthLastIndexOf(fileOnly, ".", 1);
            if (dotIx > 0) path.name = fileOnly.SubStr(0, dotIx); else path.name = fileOnly;
        }

        if (!ok) { log("LoadPath: final validation failed for " + abs, LogLevel::Error, 473, "LoadPath"); return false; }
        log("LoadPath: loaded '" + path.name + "' (mode=" + (path.mode==PathMode::Keyframes ? "keyframes" : "fn") + ", duration=" + Text::Format("%.3f", path.meta.duration) + "s, fps=" + Text::Format("%.2f", path.meta.fps) + ")", LogLevel::Info, 474, "LoadPath");

        return true;
    }

}
