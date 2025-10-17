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

        float so = meta.startOffset;
        bool gotSO = false;
             if (ReadFloat(md, "start_offset", so, so)) gotSO = true;
        else if (ReadFloat(md, "start", so, so)) gotSO = true;
        else if (ReadFloat(md, "offset", so, so)) gotSO = true;
        else if (ReadFloat(md, "resume_time", so, so)) gotSO = true;
        if (gotSO) meta.startOffset = Math::Max(0.0, so);
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
                    log("LoadFloatCurve: object key without 'u' not supported; use [u,value] pairs.", LogLevel::Warn, 134, "LoadFloatCurve");
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
                log("LoadPath: derived duration from polyline length: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, 253, "LoadFn");
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
                    log("LoadPath: used fn.duration=" + Text::Format("%.3f", fnDur) + "s", LogLevel::Info, 273, "LoadFn");
                }
            }

            float delta = Math::Abs(path.fnAscent.distEnd - path.fnAscent.distStart);
            if (path.fnAscent.distRate > 0.0 && delta > 0.0) {
                path.meta.duration = delta / path.fnAscent.distRate;
                log("LoadPath: derived duration for vertical_ascent from dist_rate: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, 280, "LoadFn");
            } else if (Math::Abs(path.fnAscent.degPerSec) > 0.0) {
                path.meta.duration = 360.0 / Math::Abs(path.fnAscent.degPerSec);
                log("LoadPath: derived duration for vertical_ascent from deg_per_sec: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, 283, "LoadFn");
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
                    log("LoadPath: derived duration from moving_orbit center length: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, 309, "LoadFn");
                } else {
                    float dps = Math::Abs(path.fnMovingOrbit.degPerSec);
                    if (dps > 0.0f) {
                        path.meta.duration = 360.0f / dps;
                        log("LoadPath: derived duration from moving_orbit deg_per_sec: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, 314, "LoadFn");
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
            log("LoadPath: not found '" + fileOrRel + "' (also looked in " + PathsDir() + ")", LogLevel::Error, -1, "PathCam::LoadPath");
            return false;
        }

        log("LoadPath: opening " + abs, LogLevel::Info, -1, "PathCam::LoadPath");

        IO::File f(abs, IO::FileMode::Read);
        string blob = f.ReadToEnd();
        f.Close();

        if (blob.Length == 0) {
            log("LoadPath: empty file: " + abs, LogLevel::Error, -1, "PathCam::LoadPath");
            return false;
        }

        auto @root = Json::Parse(blob);
        if (root is null || root.GetType() != Json::Type::Object) {
            log("LoadPath: JSON parse failed or root is not an object: " + abs, LogLevel::Error, -1, "PathCam::LoadPath");
            return false;
        }

        string mtest = "";
        ReadString(root, "mode", mtest, mtest);
        auto @resumeObj = root.Get("resume");
        bool isResume = (mtest.ToLower().StartsWith("resume") || (resumeObj !is null && resumeObj.GetType() == Json::Type::Object));
        if (isResume) {
            auto @r = (resumeObj !is null && resumeObj.GetType() == Json::Type::Object) ? resumeObj : root;

            string baseFile = "";
            if (!ReadString(r, "file", baseFile, "")) {
                log("LoadPath[resume]: missing 'file' field", LogLevel::Error, -1, "PathCam::LoadPath");
                return false;
            }

            float startOff = 0.0; ReadFloat(r, "time", startOff, 0.0);
            float startOff2; if (ReadFloat(r, "start_offset", startOff2, startOff)) startOff = startOff2;
            bool loopOverride; bool hasLoop = ReadBool(r, "loop", loopOverride, false);
            float rateOverride; bool hasRate = ReadFloat(r, "rate", rateOverride, -1.0);

            CameraPath base;
            if (!LoadPath(baseFile, base)) {
                log("LoadPath[resume]: failed to load base '" + baseFile + "'", LogLevel::Error, -1, "PathCam::LoadPath");
                return false;
            }

            base.meta.startOffset = Math::Max(0.0, startOff);
            if (hasLoop) base.meta.loop = loopOverride;
            if (hasRate && rateOverride > 0.0) base.meta.speed = rateOverride;

            string nm = "";
            ReadString(root, "name", nm, "");
            if (nm.Length > 0) base.name = nm;
            else base.name = base.name + " (resume @ " + Text::Format("%.0f", startOff) + "s)";

            path = base;
            log("LoadPath[resume]: loaded base='" + baseFile + "', start_offset=" + Text::Format("%.3f", path.meta.startOffset), LogLevel::Info, -1, "PathCam::LoadPath");
            return true;
        }

        auto @ver = root.Get("version");
        if (ver !is null && ver.GetType() != Json::Type::Null) path.version = int(ver);
        ReadString(root, "name", path.name, "");

        string modeStr = "";
        ReadString(root, "mode", modeStr, "");
        auto @fnObjCheck = root.Get("fn");
        auto @kfArrCheck = root.Get("keyframes");
        bool hasFnObj = (fnObjCheck !is null && fnObjCheck.GetType() == Json::Type::Object);
        bool hasKfArr = (kfArrCheck !is null && kfArrCheck.GetType() == Json::Type::Array);

        PathMode detected = PathMode::Keyframes;
        string ms = modeStr.ToLower();

        if (ms.StartsWith("fn")) {
            detected = PathMode::Fn;
        } else if (ms.StartsWith("key")) {
            detected = PathMode::Keyframes;
            if (hasFnObj && !hasKfArr) {
                detected = PathMode::Fn;
                log("LoadPath: corrected mode to 'fn' (file declared 'keyframes' but no keyframes; fn block present).", LogLevel::Warn, -1, "PathCam::LoadPath");
            }
        } else {
            if (hasFnObj && !hasKfArr) detected = PathMode::Fn;
            else if (hasKfArr)         detected = PathMode::Keyframes;
            else                       detected = PathMode::Fn;
        }
        path.mode = detected;

        auto @md = root.Get("metadata");
        ParseMetadata(md, path.meta);

        if (path.meta.startOffset > 0.0) {
            log("LoadPath: start_offset=" + Text::Format("%.3f", path.meta.startOffset), LogLevel::Info, -1, "PathCam::LoadPath");
        }

        if (path.meta.duration <= 0.0) {
            float topDur;
            if (ReadFloat(root, "duration", topDur, -1.0) && topDur > 0.0) {
                path.meta.duration = topDur;
                log("LoadPath: using top-level duration=" + Text::Format("%.3f", topDur), LogLevel::Info, -1, "PathCam::LoadPath");
            }
        }

        bool ok = false;
        if (path.mode == PathMode::Keyframes) {
            ok = LoadKeyframes(root, path);
            if (!ok && hasFnObj) {
                path.mode = PathMode::Fn;
                log("LoadPath: keyframes missing; falling back to 'fn' mode.", LogLevel::Warn, -1, "PathCam::LoadPath");
            }
        }

        if (path.mode == PathMode::Fn) {
            LoadFn(root, path);

            if (path.meta.duration <= 0.0) {
                auto @fnObj = root.Get("fn");
                float fnDur;
                if (ReadFloat(fnObj, "duration", fnDur, -1.0) && fnDur > 0.0) {
                    path.meta.duration = fnDur;
                    log("LoadPath: used fn.duration=" + Text::Format("%.3f", fnDur) + "s", LogLevel::Info, -1, "PathCam::LoadPath");
                }
            }

            if (path.meta.duration <= 0.0) {
                string fn = path.fnName.ToLower();
                if (fn == "orbital_circle") {
                    float dps = Math::Abs(path.fnCircle.degPerSec);
                    if (dps > 0.0) {
                        path.meta.duration = 360.0 / dps;
                        log("LoadPath: derived duration for orbital_circle: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, -1, "PathCam::LoadPath");
                    }
                } else if (fn == "orbital_helix") {
                    float dps = Math::Abs(path.fnHelix.degPerSec);
                    if (dps > 0.0) {
                        path.meta.duration = 360.0 / dps;
                        log("LoadPath: derived duration for orbital_helix: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, -1, "PathCam::LoadPath");
                    }
                } else if (fn == "target_polyline") {
                    if (path.fnPolyline.totalLen > 0.0 && path.fnPolyline.speed > 0.0) {
                        path.meta.duration = path.fnPolyline.totalLen / path.fnPolyline.speed;
                        log("LoadPath: derived duration from polyline length: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, -1, "PathCam::LoadPath");
                    }
                } else if (fn == "vertical_ascent") {
                    float delta = Math::Abs(path.fnAscent.distEnd - path.fnAscent.distStart);
                    if (path.fnAscent.distRate > 0.0 && delta > 0.0) {
                        path.meta.duration = delta / path.fnAscent.distRate;
                        log("LoadPath: derived duration for vertical_ascent from dist_rate: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, -1, "PathCam::LoadPath");
                    } else if (Math::Abs(path.fnAscent.degPerSec) > 0.0) {
                        path.meta.duration = 360.0 / Math::Abs(path.fnAscent.degPerSec);
                        log("LoadPath: derived duration for vertical_ascent from deg_per_sec: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, -1, "PathCam::LoadPath");
                    }
                }
            }

            if (path.fnName.Length == 0) {
                log("LoadPath: fn-mode but no fn.name specified", LogLevel::Error, -1, "PathCam::LoadPath");
                return false;
            }
            if (path.meta.duration <= 0.0) {
                log("LoadPath: fn-mode requires metadata.duration>0 (or derivable), currently duration=" + Text::Format("%.3f", path.meta.duration), LogLevel::Error, -1, "PathCam::LoadPath");
                return false;
            }

            ok = true;
        } else if (path.mode == PathMode::Keyframes) {
            if (!ok) {
                log("LoadPath: keyframes mode but LoadKeyframes failed / had no keyframes", LogLevel::Error, -1, "PathCam::LoadPath");
                return false;
            }
            if (path.meta.duration <= 0.0 && path.keys.Length > 0) {
                path.meta.duration = path.keys[path.keys.Length - 1].t;
                log("LoadPath: inferred duration from last keyframe: " + Text::Format("%.3f", path.meta.duration) + "s", LogLevel::Info, -1, "PathCam::LoadPath");
            }
        }

        bool anyLoop = path.meta.loop;
        bool b;

        auto @md2 = root.Get("metadata");
        if (ReadBool(md2, "loop", b, false)) anyLoop = anyLoop || b;

        if (ReadBool(root, "loop", b, false)) anyLoop = anyLoop || b;

        auto @fnObj2 = root.Get("fn");
        if (ReadBool(fnObj2, "loop", b, false)) anyLoop = anyLoop || b;

        path.meta.loop = anyLoop;

        log("LoadPath: loop=" + (path.meta.loop ? "true" : "false"), LogLevel::Info, -1, "PathCam::LoadPath");


        if (path.name.Length == 0) {
            string fileOnly = Path::GetFileName(abs);
            int dotIx = _Text::NthLastIndexOf(fileOnly, ".", 1);
            if (dotIx > 0) path.name = fileOnly.SubStr(0, dotIx); else path.name = fileOnly;
        }

        log("LoadPath: loaded '" + path.name + "' (mode=" + (path.mode==PathMode::Keyframes ? "keyframes" : "fn") + ", duration=" + Text::Format("%.3f", path.meta.duration) + "s, fps=" + Text::Format("%.2f", path.meta.fps) + (path.meta.startOffset > 0.0 ? ", start_offset=" + Text::Format("%.3f", path.meta.startOffset) : "") + ")", LogLevel::Info, -1, "PathCam::LoadPath");

        return true;
    }

}
