#!/usr/bin/env python3
# This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
# Copyright 2026 Jeff Matson.
# Written with Claude (Anthropic).
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See the LICENSE file at the repository root.
#
# Generates Whorld.xcodeproj (project.pbxproj and the shared scheme) from
# the source lists below. Run after adding or removing app, engine or
# renderer sources:  python3 mac/app/generate_project.py
# Object IDs are hashes of names, so regenerating is stable.
import hashlib, os, sys
root = os.path.dirname(os.path.abspath(__file__))  # mac/app
def gid(name):
    return hashlib.md5(name.encode()).hexdigest()[:24].upper()

app_files = ["WhorldApp.swift", "ContentView.swift", "Commands.swift", "Panels.swift", "Preferences.swift", "Mapping.swift", "Media.swift", "FullScreen.swift", "Workspace.swift", "Updates.swift", "KeyMap.swift", "Modulation.swift",
             "WHOscServer.h", "WHOscServer.mm", "WHSyphon.h", "WHSyphon.mm", "WHAudioInput.h", "WHAudioInput.mm", "WHLink.h", "WHLink.mm",
             "WHEngine.h", "WHEngine.mm",
             "Whorld-Bridging-Header.h", "Info.plist", "AppIcon.icns"]
engine_src = sorted(f for f in os.listdir(os.path.join(root, "../engine/src")) if f.endswith(".cpp"))
renderer_src = ["CGRenderer.mm", "VideoWriter.mm", "MetalRenderer.mm", "gpu/Tessellator.cpp"]
groups = [("Whorld", "Whorld", app_files), ("Engine", "../engine/src", engine_src), ("Renderer", "../renderer", renderer_src)]
ftype = {".swift": "sourcecode.swift", ".h": "sourcecode.c.h", ".mm": "sourcecode.cpp.objcpp",
         ".cpp": "sourcecode.cpp.cpp", ".plist": "text.plist.xml", ".icns": "image.icns"}
compiled = (".swift", ".mm", ".cpp")
resources = (".icns",)
# Copies the help into Contents/Resources/Help: the Mac page (mac/app/Help)
# and the Whorld manual (docs/Help) as Help/V1, with the icon its contents
# page links to. Opened by Help > Whorld Help.
help_script = r'''H="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Help"
mkdir -p "$H/V1" "$H/images"
rsync -a --delete --exclude V1 --exclude images "$SRCROOT/Help/" "$H/"
rsync -a --delete "$SRCROOT/../../docs/Help/" "$H/V1/"
cp "$SRCROOT/../../docs/images/whorld-icon-32x32.gif" "$H/images/"
'''
# Builds Syphon.framework (the mac/third_party/Syphon-Framework submodule,
# BSD license) for this build's architectures into the products folder,
# where the app links it; a clean environment keeps this build's settings
# out of Syphon's. Quick when nothing changed.
syphon_build_script = r'''SY="$SRCROOT/../third_party/Syphon-Framework"
if [ ! -f "$SY/Syphon.xcodeproj/project.pbxproj" ]; then
  echo "error: Syphon is missing: run 'git submodule update --init' in the repository"
  exit 1
fi
OUT="$PROJECT_TEMP_DIR/SyphonBuild"
env -i PATH="$PATH" HOME="$HOME" DEVELOPER_DIR="$DEVELOPER_DIR" xcodebuild -quiet \
  -project "$SY/Syphon.xcodeproj" -scheme Syphon -configuration Release \
  ARCHS="$ARCHS" ONLY_ACTIVE_ARCH=NO MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
  CODE_SIGNING_ALLOWED=NO SYMROOT="$OUT" OBJROOT="$OUT/obj" build || exit 1
mkdir -p "$BUILT_PRODUCTS_DIR"
rsync -a --delete "$OUT/Release/Syphon.framework/" "$BUILT_PRODUCTS_DIR/Syphon.framework/"
'''
# Puts Syphon.framework in the app's Frameworks folder, signed (ad hoc, as
# the app is) so the app's signature covers it.
syphon_embed_script = r'''F="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$F"
rsync -a --delete "$BUILT_PRODUCTS_DIR/Syphon.framework/" "$F/Syphon.framework/"
codesign --force --sign - --timestamp=none "$F/Syphon.framework"
'''

def pbxstr(t):
    return '"' + t.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'

o = []
w = o.append
w("// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n")
w("\n/* Begin PBXBuildFile section */\n")
for g, path, files in groups:
    for f in files:
        if os.path.splitext(f)[1] in compiled:
            w(f"\t\t{gid('bf'+g+f)} /* {f} in Sources */ = {{isa = PBXBuildFile; fileRef = {gid('fr'+g+f)} /* {f} */; }};\n")
        if os.path.splitext(f)[1] in resources:
            w(f"\t\t{gid('bf'+g+f)} /* {f} in Resources */ = {{isa = PBXBuildFile; fileRef = {gid('fr'+g+f)} /* {f} */; }};\n")
w("/* End PBXBuildFile section */\n\n/* Begin PBXFileReference section */\n")
w(f"\t\t{gid('product')} /* Whorld.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Whorld.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n")
for g, path, files in groups:
    for f in files:
        t = ftype[os.path.splitext(f)[1]]
        w(f"\t\t{gid('fr'+g+f)} /* {f} */ = {{isa = PBXFileReference; lastKnownFileType = {t}; path = \"{f}\"; sourceTree = \"<group>\"; }};\n")
w("/* End PBXFileReference section */\n\n/* Begin PBXFrameworksBuildPhase section */\n")
w(f"\t\t{gid('frameworks')} /* Frameworks */ = {{\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t}};\n")
w("/* End PBXFrameworksBuildPhase section */\n\n/* Begin PBXGroup section */\n")
w(f"\t\t{gid('maingroup')} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n")
for g, path, files in groups:
    w(f"\t\t\t\t{gid('group'+g)} /* {g} */,\n")
w(f"\t\t\t\t{gid('products')} /* Products */,\n\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
w(f"\t\t{gid('products')} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t\t{gid('product')} /* Whorld.app */,\n\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
for g, path, files in groups:
    w(f"\t\t{gid('group'+g)} /* {g} */ = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n")
    for f in files:
        w(f"\t\t\t\t{gid('fr'+g+f)} /* {f} */,\n")
    w(f"\t\t\t);\n\t\t\tname = {g};\n\t\t\tpath = \"{path}\";\n\t\t\tsourceTree = \"<group>\";\n\t\t}};\n")
w("/* End PBXGroup section */\n\n/* Begin PBXNativeTarget section */\n")
w(f"""\t\t{gid('target')} /* Whorld */ = {{
\t\t\tisa = PBXNativeTarget;
\t\t\tbuildConfigurationList = {gid('targetconfigs')} /* Build configuration list for PBXNativeTarget "Whorld" */;
\t\t\tbuildPhases = (
\t\t\t\t{gid('syphonbuild')} /* Build Syphon */,
\t\t\t\t{gid('sources')} /* Sources */,
\t\t\t\t{gid('frameworks')} /* Frameworks */,
\t\t\t\t{gid('syphonembed')} /* Embed Syphon */,
\t\t\t\t{gid('resources')} /* Resources */,
\t\t\t\t{gid('helpscript')} /* Copy Help */,
\t\t\t);
\t\t\tbuildRules = (
\t\t\t);
\t\t\tdependencies = (
\t\t\t);
\t\t\tname = Whorld;
\t\t\tproductName = Whorld;
\t\t\tproductReference = {gid('product')} /* Whorld.app */;
\t\t\tproductType = "com.apple.product-type.application";
\t\t}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
\t\t{gid('project')} /* Project object */ = {{
\t\t\tisa = PBXProject;
\t\t\tattributes = {{
\t\t\t\tBuildIndependentTargetsInParallel = 1;
\t\t\t\tLastSwiftUpdateCheck = 1620;
\t\t\t\tLastUpgradeCheck = 1620;
\t\t\t}};
\t\t\tbuildConfigurationList = {gid('projconfigs')} /* Build configuration list for PBXProject "Whorld" */;
\t\t\tcompatibilityVersion = "Xcode 14.0";
\t\t\tdevelopmentRegion = en;
\t\t\thasScannedForEncodings = 0;
\t\t\tknownRegions = (
\t\t\t\ten,
\t\t\t\tBase,
\t\t\t);
\t\t\tmainGroup = {gid('maingroup')};
\t\t\tproductRefGroup = {gid('products')} /* Products */;
\t\t\tprojectDirPath = "";
\t\t\tprojectRoot = "";
\t\t\ttargets = (
\t\t\t\t{gid('target')} /* Whorld */,
\t\t\t);
\t\t}};
/* End PBXProject section */

/* Begin PBXSourcesBuildPhase section */
\t\t{gid('sources')} /* Sources */ = {{
\t\t\tisa = PBXSourcesBuildPhase;
\t\t\tbuildActionMask = 2147483647;
\t\t\tfiles = (
""")
for g, path, files in groups:
    for f in files:
        if os.path.splitext(f)[1] in compiled:
            w(f"\t\t\t\t{gid('bf'+g+f)} /* {f} in Sources */,\n")
w("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n/* End PBXSourcesBuildPhase section */\n\n")
w(f"/* Begin PBXResourcesBuildPhase section */\n\t\t{gid('resources')} /* Resources */ = {{\n\t\t\tisa = PBXResourcesBuildPhase;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n")
for g, path, files in groups:
    for f in files:
        if os.path.splitext(f)[1] in resources:
            w(f"\t\t\t\t{gid('bf'+g+f)} /* {f} in Resources */,\n")
w("\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t};\n/* End PBXResourcesBuildPhase section */\n\n")
def script_phase(key, name, script):
    w(f"\t\t{gid(key)} /* {name} */ = {{\n\t\t\tisa = PBXShellScriptBuildPhase;\n\t\t\talwaysOutOfDate = 1;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\tinputPaths = (\n\t\t\t);\n\t\t\tname = \"{name}\";\n\t\t\toutputPaths = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t\tshellPath = /bin/sh;\n\t\t\tshellScript = {pbxstr(script)};\n\t\t}};\n")
w("/* Begin PBXShellScriptBuildPhase section */\n")
script_phase('syphonbuild', 'Build Syphon', syphon_build_script)
script_phase('syphonembed', 'Embed Syphon', syphon_embed_script)
w(f"\t\t{gid('helpscript')} /* Copy Help */ = {{\n\t\t\tisa = PBXShellScriptBuildPhase;\n\t\t\talwaysOutOfDate = 1;\n\t\t\tbuildActionMask = 2147483647;\n\t\t\tfiles = (\n\t\t\t);\n\t\t\tinputPaths = (\n\t\t\t);\n\t\t\tname = \"Copy Help\";\n\t\t\toutputPaths = (\n\t\t\t);\n\t\t\trunOnlyForDeploymentPostprocessing = 0;\n\t\t\tshellPath = /bin/sh;\n\t\t\tshellScript = {pbxstr(help_script)};\n\t\t}};\n/* End PBXShellScriptBuildPhase section */\n\n/* Begin XCBuildConfiguration section */\n")
common = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tCLANG_CXX_LANGUAGE_STANDARD = "c++17";
\t\t\t\tCLANG_CXX_LIBRARY = "libc++";
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = NO;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;
\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 14.0;
\t\t\t\tSDKROOT = macosx;
"""
for cfg in ("Debug", "Release"):
    extra = ("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;\n\t\t\t\tENABLE_TESTABILITY = YES;\n\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;\n\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (\n\t\t\t\t\t\"DEBUG=1\",\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t);\n\t\t\t\tONLY_ACTIVE_ARCH = YES;\n\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;\n\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";\n"
             if cfg == "Debug" else
             "\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";\n\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (\n\t\t\t\t\t\"NDEBUG=1\",\n\t\t\t\t\t\"$(inherited)\",\n\t\t\t\t);\n\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;\n\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-O\";\n")
    w(f"\t\t{gid('projcfg'+cfg)} /* {cfg} */ = {{\n\t\t\tisa = XCBuildConfiguration;\n\t\t\tbuildSettings = {{\n{common}{extra}\t\t\t}};\n\t\t\tname = {cfg};\n\t\t}};\n")
for cfg in ("Debug", "Release"):
    w(f"""\t\t{gid('tgtcfg'+cfg)} /* {cfg} */ = {{
\t\t\tisa = XCBuildConfiguration;
\t\t\tbuildSettings = {{
\t\t\t\tCODE_SIGN_IDENTITY = "-";
\t\t\t\tCODE_SIGN_STYLE = Manual;
\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;
\t\t\t\tCURRENT_PROJECT_VERSION = 10;
\t\t\t\tENABLE_HARDENED_RUNTIME = NO;
\t\t\t\tENABLE_USER_SCRIPT_SANDBOXING = NO;
\t\t\t\tFRAMEWORK_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"$(BUILT_PRODUCTS_DIR)",
\t\t\t\t);
\t\t\t\tHEADER_SEARCH_PATHS = (
\t\t\t\t\t"$(SRCROOT)/../engine/include",
\t\t\t\t\t"$(SRCROOT)/../engine/src",
\t\t\t\t\t"$(SRCROOT)/../renderer",
\t\t\t\t\t"$(SRCROOT)/../third_party/link/include",
\t\t\t\t\t"$(SRCROOT)/../third_party/link/modules/asio-standalone/asio/include",
\t\t\t\t);
\t\t\t\tINFOPLIST_FILE = Whorld/Info.plist;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/../Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 0.1;
\t\t\t\tOTHER_LDFLAGS = (
\t\t\t\t\t"-framework",
\t\t\t\t\tCoreGraphics,
\t\t\t\t\t"-framework",
\t\t\t\t\tImageIO,
\t\t\t\t\t"-framework",
\t\t\t\t\tQuartzCore,
\t\t\t\t\t"-framework",
\t\t\t\t\tCoreMIDI,
\t\t\t\t\t"-framework",
\t\t\t\t\tCoreAudio,
\t\t\t\t\t"-framework",
\t\t\t\t\tAudioToolbox,
\t\t\t\t\t"-framework",
\t\t\t\t\tAVFoundation,
\t\t\t\t\t"-framework",
\t\t\t\t\tCoreVideo,
\t\t\t\t\t"-framework",
\t\t\t\t\tCoreMedia,
\t\t\t\t\t"-framework",
\t\t\t\t\tMetal,
\t\t\t\t\t"-framework",
\t\t\t\t\tIOSurface,
\t\t\t\t\t"-framework",
\t\t\t\t\tSyphon,
\t\t\t\t);
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = "io.github.bzsqrl.Whorld";
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_OBJC_BRIDGING_HEADER = "Whorld/Whorld-Bridging-Header.h";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t}};
\t\t\tname = {cfg};
\t\t}};
""")
w("/* End XCBuildConfiguration section */\n\n/* Begin XCConfigurationList section */\n")
for lid, cid, desc in (("projconfigs", "projcfg", 'PBXProject "Whorld"'), ("targetconfigs", "tgtcfg", 'PBXNativeTarget "Whorld"')):
    w(f"\t\t{gid(lid)} /* Build configuration list for {desc} */ = {{\n\t\t\tisa = XCConfigurationList;\n\t\t\tbuildConfigurations = (\n\t\t\t\t{gid(cid+'Debug')} /* Debug */,\n\t\t\t\t{gid(cid+'Release')} /* Release */,\n\t\t\t);\n\t\t\tdefaultConfigurationIsVisible = 0;\n\t\t\tdefaultConfigurationName = Release;\n\t\t}};\n")
w("/* End XCConfigurationList section */\n\t};\n\trootObject = " + gid('project') + " /* Project object */;\n}\n")
proj = os.path.join(root, "Whorld.xcodeproj")
os.makedirs(os.path.join(proj, "xcshareddata/xcschemes"), exist_ok=True)
open(os.path.join(proj, "project.pbxproj"), "w").write("".join(o))
t = gid('target'); p = gid('product')
ref = f"""<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{t}" BuildableName = "Whorld.app" BlueprintName = "Whorld" ReferencedContainer = "container:Whorld.xcodeproj"></BuildableReference>"""
open(os.path.join(proj, "xcshareddata/xcschemes/Whorld.xcscheme"), "w").write(f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "1620" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            {ref}
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         {ref}
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"></AnalyzeAction>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"></ArchiveAction>
</Scheme>
""")
print("ok", len(engine_src), "engine sources")
