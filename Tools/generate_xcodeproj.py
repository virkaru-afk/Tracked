#!/usr/bin/env python3
"""Generate TripleJump.xcodeproj/project.pbxproj.

Run after adding or removing a Swift file:

    python3 Tools/generate_xcodeproj.py

Hand-written because neither xcodegen nor tuist is installed, and a .pbxproj
is not a file anyone should be editing by hand for routine changes like "a new
source file exists". Object IDs are md5-derived from stable keys, so
regenerating produces a byte-identical file rather than churn.

Editing the project in Xcode's UI is fine, but anything set there is lost on
the next regeneration. Settings that must survive belong in APP_COMMON below —
DEVELOPMENT_TEAM in particular.
"""
import hashlib
import pathlib

# Derived from this file's location, so the project can be moved or renamed
# without editing anything here.
ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJ = ROOT / "TripleJump.xcodeproj"

def oid(key: str) -> str:
    return hashlib.md5(key.encode()).hexdigest()[:24].upper()

# ---- file inventory -------------------------------------------------------
lib_sources = sorted(p.name for p in (ROOT / "Sources/TJApp").glob("*.swift"))
app_sources = ["TripleJumpApp.swift"]
test_sources = sorted(p.name for p in (ROOT / "Tests/TJAppTests").glob("*.swift"))

APP_TARGET = "TripleJump"
TEST_TARGET = "TripleJumpTests"

# ---- ids ------------------------------------------------------------------
PROJECT = oid("project")
MAIN_GROUP = oid("group.main")
PRODUCTS_GROUP = oid("group.products")
APP_GROUP = oid("group.app")
LIB_GROUP = oid("group.lib")
TESTS_GROUP = oid("group.tests")

APP_TGT = oid("target.app")
TEST_TGT = oid("target.tests")
APP_PRODUCT = oid("product.app")
TEST_PRODUCT = oid("product.tests")

APP_SOURCES_PHASE = oid("phase.app.sources")
APP_FRAMEWORKS_PHASE = oid("phase.app.frameworks")
APP_RESOURCES_PHASE = oid("phase.app.resources")
TEST_SOURCES_PHASE = oid("phase.test.sources")
TEST_FRAMEWORKS_PHASE = oid("phase.test.frameworks")
TEST_RESOURCES_PHASE = oid("phase.test.resources")

PROJ_CFG_LIST = oid("cfglist.project")
APP_CFG_LIST = oid("cfglist.app")
TEST_CFG_LIST = oid("cfglist.tests")
PROJ_DEBUG = oid("cfg.project.debug")
PROJ_RELEASE = oid("cfg.project.release")
APP_DEBUG = oid("cfg.app.debug")
APP_RELEASE = oid("cfg.app.release")
TEST_DEBUG = oid("cfg.tests.debug")
TEST_RELEASE = oid("cfg.tests.release")
TEST_DEP = oid("dep.tests.app")
TEST_DEP_PROXY = oid("dep.tests.app.proxy")
INFO_PLIST_REF = oid("file.infoplist")

FRAMEWORKS_GROUP = oid("group.frameworks")
RESOURCES_GROUP = oid("group.resources")
XCFRAMEWORKS = ["MediaPipeTasksVision.xcframework", "MediaPipeTasksCommon.xcframework"]
MODEL = "pose_landmarker_heavy.task"

def fref(path: str) -> str:
    return oid("fileref." + path)

def bfile(path: str, target: str) -> str:
    return oid("buildfile." + target + "." + path)

# ---- emit -----------------------------------------------------------------
out = []
w = out.append

w("// !$*UTF8*$!")
w("{")
w("\tarchiveVersion = 1;")
w("\tclasses = {")
w("\t};")
w("\tobjectVersion = 56;")
w("\tobjects = {")

# PBXBuildFile
w("\n/* Begin PBXBuildFile section */")
for name in app_sources:
    p = "App/" + name
    w("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
      % (bfile(p, APP_TARGET), name, fref(p), name))
for name in lib_sources:
    p = "Sources/TJApp/" + name
    w("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
      % (bfile(p, APP_TARGET), name, fref(p), name))
for name in test_sources:
    p = "Tests/TJAppTests/" + name
    w("\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
      % (bfile(p, TEST_TARGET), name, fref(p), name))
for name in XCFRAMEWORKS:
    p = "Frameworks/" + name
    w("\t\t%s /* %s in Frameworks */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
      % (bfile(p, APP_TARGET), name, fref(p), name))
w("\t\t%s /* %s in Resources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };"
  % (bfile("Resources/" + MODEL, APP_TARGET), MODEL, fref("Resources/" + MODEL), MODEL))
w("/* End PBXBuildFile section */")

# PBXContainerItemProxy
w("\n/* Begin PBXContainerItemProxy section */")
w("\t\t%s /* PBXContainerItemProxy */ = {" % TEST_DEP_PROXY)
w("\t\t\tisa = PBXContainerItemProxy;")
w("\t\t\tcontainerPortal = %s /* Project object */;" % PROJECT)
w("\t\t\tproxyType = 1;")
w("\t\t\tremoteGlobalIDString = %s;" % APP_TGT)
w("\t\t\tremoteInfo = %s;" % APP_TARGET)
w("\t\t};")
w("/* End PBXContainerItemProxy section */")

# PBXFileReference
w("\n/* Begin PBXFileReference section */")
w('\t\t%s /* %s.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; '
  'includeInIndex = 0; path = %s.app; sourceTree = BUILT_PRODUCTS_DIR; };'
  % (APP_PRODUCT, APP_TARGET, APP_TARGET))
w('\t\t%s /* %s.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; '
  'includeInIndex = 0; path = %s.xctest; sourceTree = BUILT_PRODUCTS_DIR; };'
  % (TEST_PRODUCT, TEST_TARGET, TEST_TARGET))
w('\t\t%s /* Info.plist */ = {isa = PBXFileReference; lastKnownFileType = text.plist.xml; '
  'path = Info.plist; sourceTree = "<group>"; };' % INFO_PLIST_REF)
for name in app_sources:
    w('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
      'path = %s; sourceTree = "<group>"; };' % (fref("App/" + name), name, name))
for name in lib_sources:
    w('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
      'path = %s; sourceTree = "<group>"; };' % (fref("Sources/TJApp/" + name), name, name))
for name in test_sources:
    w('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; '
      'path = %s; sourceTree = "<group>"; };' % (fref("Tests/TJAppTests/" + name), name, name))
for name in XCFRAMEWORKS:
    w('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; '
      'path = %s; sourceTree = "<group>"; };' % (fref("Frameworks/" + name), name, name))
w('\t\t%s /* %s */ = {isa = PBXFileReference; lastKnownFileType = file; '
  'path = %s; sourceTree = "<group>"; };'
  % (fref("Resources/" + MODEL), MODEL, MODEL))
w("/* End PBXFileReference section */")

# PBXFrameworksBuildPhase
w("\n/* Begin PBXFrameworksBuildPhase section */")
for pid in (APP_FRAMEWORKS_PHASE, TEST_FRAMEWORKS_PHASE):
    w("\t\t%s /* Frameworks */ = {" % pid)
    w("\t\t\tisa = PBXFrameworksBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    # Only the app links MediaPipe. The test target inherits it through
    # BUNDLE_LOADER/TEST_HOST, and linking static frameworks into both would
    # duplicate every symbol.
    if pid == APP_FRAMEWORKS_PHASE:
        for name in XCFRAMEWORKS:
            w("\t\t\t\t%s /* %s in Frameworks */,"
              % (bfile("Frameworks/" + name, APP_TARGET), name))
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
w("/* End PBXFrameworksBuildPhase section */")

# PBXGroup
w("\n/* Begin PBXGroup section */")
w("\t\t%s = {" % MAIN_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w("\t\t\t\t%s /* App */," % APP_GROUP)
w("\t\t\t\t%s /* TJApp */," % LIB_GROUP)
w("\t\t\t\t%s /* TJAppTests */," % TESTS_GROUP)
w("\t\t\t\t%s /* Frameworks */," % FRAMEWORKS_GROUP)
w("\t\t\t\t%s /* Resources */," % RESOURCES_GROUP)
w("\t\t\t\t%s /* Products */," % PRODUCTS_GROUP)
w("\t\t\t);")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w("\t\t%s /* Products */ = {" % PRODUCTS_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w("\t\t\t\t%s /* %s.app */," % (APP_PRODUCT, APP_TARGET))
w("\t\t\t\t%s /* %s.xctest */," % (TEST_PRODUCT, TEST_TARGET))
w("\t\t\t);")
w("\t\t\tname = Products;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w("\t\t%s /* App */ = {" % APP_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
for name in app_sources:
    w("\t\t\t\t%s /* %s */," % (fref("App/" + name), name))
w("\t\t\t\t%s /* Info.plist */," % INFO_PLIST_REF)
w("\t\t\t);")
w("\t\t\tpath = App;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w("\t\t%s /* TJApp */ = {" % LIB_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
for name in lib_sources:
    w("\t\t\t\t%s /* %s */," % (fref("Sources/TJApp/" + name), name))
w("\t\t\t);")
w("\t\t\tname = TJApp;")
w("\t\t\tpath = Sources/TJApp;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w("\t\t%s /* TJAppTests */ = {" % TESTS_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
for name in test_sources:
    w("\t\t\t\t%s /* %s */," % (fref("Tests/TJAppTests/" + name), name))
w("\t\t\t);")
w("\t\t\tname = TJAppTests;")
w("\t\t\tpath = Tests/TJAppTests;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w("\t\t%s /* Frameworks */ = {" % FRAMEWORKS_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
for name in XCFRAMEWORKS:
    w("\t\t\t\t%s /* %s */," % (fref("Frameworks/" + name), name))
w("\t\t\t);")
w("\t\t\tpath = Frameworks;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")

w("\t\t%s /* Resources */ = {" % RESOURCES_GROUP)
w("\t\t\tisa = PBXGroup;")
w("\t\t\tchildren = (")
w("\t\t\t\t%s /* %s */," % (fref("Resources/" + MODEL), MODEL))
w("\t\t\t);")
w("\t\t\tpath = Resources;")
w("\t\t\tsourceTree = \"<group>\";")
w("\t\t};")
w("/* End PBXGroup section */")

# PBXNativeTarget
w("\n/* Begin PBXNativeTarget section */")
w("\t\t%s /* %s */ = {" % (APP_TGT, APP_TARGET))
w("\t\t\tisa = PBXNativeTarget;")
w("\t\t\tbuildConfigurationList = %s;" % APP_CFG_LIST)
w("\t\t\tbuildPhases = (")
w("\t\t\t\t%s /* Sources */," % APP_SOURCES_PHASE)
w("\t\t\t\t%s /* Frameworks */," % APP_FRAMEWORKS_PHASE)
w("\t\t\t\t%s /* Resources */," % APP_RESOURCES_PHASE)
w("\t\t\t);")
w("\t\t\tbuildRules = (")
w("\t\t\t);")
w("\t\t\tdependencies = (")
w("\t\t\t);")
w("\t\t\tname = %s;" % APP_TARGET)
w("\t\t\tproductName = %s;" % APP_TARGET)
w("\t\t\tproductReference = %s /* %s.app */;" % (APP_PRODUCT, APP_TARGET))
w("\t\t\tproductType = \"com.apple.product-type.application\";")
w("\t\t};")

w("\t\t%s /* %s */ = {" % (TEST_TGT, TEST_TARGET))
w("\t\t\tisa = PBXNativeTarget;")
w("\t\t\tbuildConfigurationList = %s;" % TEST_CFG_LIST)
w("\t\t\tbuildPhases = (")
w("\t\t\t\t%s /* Sources */," % TEST_SOURCES_PHASE)
w("\t\t\t\t%s /* Frameworks */," % TEST_FRAMEWORKS_PHASE)
w("\t\t\t\t%s /* Resources */," % TEST_RESOURCES_PHASE)
w("\t\t\t);")
w("\t\t\tbuildRules = (")
w("\t\t\t);")
w("\t\t\tdependencies = (")
w("\t\t\t\t%s /* PBXTargetDependency */," % TEST_DEP)
w("\t\t\t);")
w("\t\t\tname = %s;" % TEST_TARGET)
w("\t\t\tproductName = %s;" % TEST_TARGET)
w("\t\t\tproductReference = %s /* %s.xctest */;" % (TEST_PRODUCT, TEST_TARGET))
w("\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";")
w("\t\t};")
w("/* End PBXNativeTarget section */")

# PBXProject
w("\n/* Begin PBXProject section */")
w("\t\t%s /* Project object */ = {" % PROJECT)
w("\t\t\tisa = PBXProject;")
w("\t\t\tattributes = {")
w("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
w("\t\t\t\tLastSwiftUpdateCheck = 2660;")
w("\t\t\t\tLastUpgradeCheck = 2660;")
w("\t\t\t\tTargetAttributes = {")
w("\t\t\t\t\t%s = {" % APP_TGT)
w("\t\t\t\t\t\tCreatedOnToolsVersion = 26.6;")
w("\t\t\t\t\t};")
w("\t\t\t\t\t%s = {" % TEST_TGT)
w("\t\t\t\t\t\tCreatedOnToolsVersion = 26.6;")
w("\t\t\t\t\t\tTestTargetID = %s;" % APP_TGT)
w("\t\t\t\t\t};")
w("\t\t\t\t};")
w("\t\t\t};")
w("\t\t\tbuildConfigurationList = %s;" % PROJ_CFG_LIST)
w("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
w("\t\t\tdevelopmentRegion = en;")
w("\t\t\thasScannedForEncodings = 0;")
w("\t\t\tknownRegions = (")
w("\t\t\t\ten,")
w("\t\t\t\tBase,")
w("\t\t\t);")
w("\t\t\tmainGroup = %s;" % MAIN_GROUP)
w("\t\t\tproductRefGroup = %s /* Products */;" % PRODUCTS_GROUP)
w("\t\t\tprojectDirPath = \"\";")
w("\t\t\tprojectRoot = \"\";")
w("\t\t\ttargets = (")
w("\t\t\t\t%s /* %s */," % (APP_TGT, APP_TARGET))
w("\t\t\t\t%s /* %s */," % (TEST_TGT, TEST_TARGET))
w("\t\t\t);")
w("\t\t};")
w("/* End PBXProject section */")

# PBXResourcesBuildPhase
w("\n/* Begin PBXResourcesBuildPhase section */")
for pid in (APP_RESOURCES_PHASE, TEST_RESOURCES_PHASE):
    w("\t\t%s /* Resources */ = {" % pid)
    w("\t\t\tisa = PBXResourcesBuildPhase;")
    w("\t\t\tbuildActionMask = 2147483647;")
    w("\t\t\tfiles = (")
    if pid == APP_RESOURCES_PHASE:
        w("\t\t\t\t%s /* %s in Resources */,"
          % (bfile("Resources/" + MODEL, APP_TARGET), MODEL))
    w("\t\t\t);")
    w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    w("\t\t};")
w("/* End PBXResourcesBuildPhase section */")

# PBXSourcesBuildPhase
w("\n/* Begin PBXSourcesBuildPhase section */")
w("\t\t%s /* Sources */ = {" % APP_SOURCES_PHASE)
w("\t\t\tisa = PBXSourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for name in lib_sources:
    p = "Sources/TJApp/" + name
    w("\t\t\t\t%s /* %s in Sources */," % (bfile(p, APP_TARGET), name))
for name in app_sources:
    p = "App/" + name
    w("\t\t\t\t%s /* %s in Sources */," % (bfile(p, APP_TARGET), name))
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")

w("\t\t%s /* Sources */ = {" % TEST_SOURCES_PHASE)
w("\t\t\tisa = PBXSourcesBuildPhase;")
w("\t\t\tbuildActionMask = 2147483647;")
w("\t\t\tfiles = (")
for name in test_sources:
    p = "Tests/TJAppTests/" + name
    w("\t\t\t\t%s /* %s in Sources */," % (bfile(p, TEST_TARGET), name))
w("\t\t\t);")
w("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
w("\t\t};")
w("/* End PBXSourcesBuildPhase section */")

# PBXTargetDependency
w("\n/* Begin PBXTargetDependency section */")
w("\t\t%s /* PBXTargetDependency */ = {" % TEST_DEP)
w("\t\t\tisa = PBXTargetDependency;")
w("\t\t\ttarget = %s /* %s */;" % (APP_TGT, APP_TARGET))
w("\t\t\ttargetProxy = %s /* PBXContainerItemProxy */;" % TEST_DEP_PROXY)
w("\t\t};")
w("/* End PBXTargetDependency section */")

# XCBuildConfiguration
COMMON = """\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;
\t\t\t\tASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
\t\t\t\tCLANG_ANALYZER_NONNULL = YES;
\t\t\t\tCLANG_ANALYZER_NUMBER_OBJECT_CONVERSION = YES_AGGRESSIVE;
\t\t\t\tCLANG_ENABLE_MODULES = YES;
\t\t\t\tCLANG_ENABLE_OBJC_ARC = YES;
\t\t\t\tCLANG_WARN_BOOL_CONVERSION = YES;
\t\t\t\tCLANG_WARN_DIRECT_OBJC_ISA_USAGE = YES_ERROR;
\t\t\t\tCLANG_WARN_DOCUMENTATION_COMMENTS = YES;
\t\t\t\tCLANG_WARN_EMPTY_BODY = YES;
\t\t\t\tCLANG_WARN_ENUM_CONVERSION = YES;
\t\t\t\tCLANG_WARN_INT_CONVERSION = YES;
\t\t\t\tCLANG_WARN_OBJC_ROOT_CLASS = YES_ERROR;
\t\t\t\tCLANG_WARN_UNREACHABLE_CODE = YES;
\t\t\t\tCOPY_PHASE_STRIP = NO;
\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;
\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;
\t\t\t\tGCC_NO_COMMON_BLOCKS = YES;
\t\t\t\tGCC_WARN_64_TO_32_BIT_CONVERSION = YES;
\t\t\t\tGCC_WARN_ABOUT_RETURN_TYPE = YES_ERROR;
\t\t\t\tGCC_WARN_UNDECLARED_SELECTOR = YES;
\t\t\t\tGCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE;
\t\t\t\tGCC_WARN_UNUSED_FUNCTION = YES;
\t\t\t\tGCC_WARN_UNUSED_VARIABLE = YES;
\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 17.0;
\t\t\t\tLOCALIZATION_PREFERS_STRING_CATALOGS = YES;
\t\t\t\tSDKROOT = iphoneos;
\t\t\t\tSUPPORTED_PLATFORMS = "iphoneos iphonesimulator";
\t\t\t\tSUPPORTS_MACCATALYST = NO;
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;"""

w("\n/* Begin XCBuildConfiguration section */")
w("\t\t%s /* Debug */ = {" % PROJ_DEBUG)
w("\t\t\tisa = XCBuildConfiguration;")
w("\t\t\tbuildSettings = {")
w(COMMON)
w("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
w("\t\t\t\tENABLE_TESTABILITY = YES;")
w("\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;")
w("\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;")
w("\t\t\t\tGCC_PREPROCESSOR_DEFINITIONS = (")
w("\t\t\t\t\t\"DEBUG=1\",")
w("\t\t\t\t\t\"$(inherited)\",")
w("\t\t\t\t);")
w("\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;")
w("\t\t\t\tONLY_ACTIVE_ARCH = YES;")
w("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = \"DEBUG $(inherited)\";")
w("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";")
w("\t\t\t};")
w("\t\t\tname = Debug;")
w("\t\t};")

w("\t\t%s /* Release */ = {" % PROJ_RELEASE)
w("\t\t\tisa = XCBuildConfiguration;")
w("\t\t\tbuildSettings = {")
w(COMMON)
w("\t\t\t\tDEBUG_INFORMATION_FORMAT = \"dwarf-with-dsym\";")
w("\t\t\t\tENABLE_NS_ASSERTIONS = NO;")
w("\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;")
w("\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
w("\t\t\t};")
w("\t\t\tname = Release;")
w("\t\t};")

APP_COMMON = """\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tENABLE_PREVIEWS = YES;
\t\t\t\tFRAMEWORK_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"$(SRCROOT)/Frameworks",
\t\t\t\t);
\t\t\t\tOTHER_LDFLAGS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"-lc++",
\t\t\t\t\t"-framework", "Accelerate",
\t\t\t\t\t"-framework", "AVFoundation",
\t\t\t\t\t"-framework", "CoreGraphics",
\t\t\t\t\t"-framework", "CoreImage",
\t\t\t\t\t"-framework", "CoreMedia",
\t\t\t\t\t"-framework", "CoreVideo",
\t\t\t\t\t"-framework", "QuartzCore",
\t\t\t\t);
\t\t\t\t"OTHER_LDFLAGS[sdk=iphoneos*]" = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"-force_load",
\t\t\t\t\t"$(SRCROOT)/Frameworks/graph_libraries/libMediaPipeTasksCommon_device_graph.a",
\t\t\t\t);
\t\t\t\t"OTHER_LDFLAGS[sdk=iphonesimulator*]" = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"-force_load",
\t\t\t\t\t"$(SRCROOT)/Frameworks/graph_libraries/libMediaPipeTasksCommon_simulator_graph.a",
\t\t\t\t);
\t\t\t\tGENERATE_INFOPLIST_FILE = NO;
\t\t\t\tINFOPLIST_FILE = App/Info.plist;
\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (
\t\t\t\t\t"$(inherited)",
\t\t\t\t\t"@executable_path/Frameworks",
\t\t\t\t);
\t\t\t\tMARKETING_VERSION = 0.1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.triplejump.TripleJump;
\t\t\t\tPRODUCT_MODULE_NAME = TJApp;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = 1;"""

for cid, cname in ((APP_DEBUG, "Debug"), (APP_RELEASE, "Release")):
    w("\t\t%s /* %s */ = {" % (cid, cname))
    w("\t\t\tisa = XCBuildConfiguration;")
    w("\t\t\tbuildSettings = {")
    w(APP_COMMON)
    w("\t\t\t};")
    w("\t\t\tname = %s;" % cname)
    w("\t\t};")

TEST_COMMON = """\t\t\t\tALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES = YES;
\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";
\t\t\t\tCODE_SIGN_STYLE = Automatic;
\t\t\t\tCURRENT_PROJECT_VERSION = 1;
\t\t\t\tDEVELOPMENT_TEAM = "";
\t\t\t\tGENERATE_INFOPLIST_FILE = YES;
\t\t\t\tMARKETING_VERSION = 0.1.0;
\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.triplejump.TripleJumpTests;
\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";
\t\t\t\tSWIFT_VERSION = 5.0;
\t\t\t\tTARGETED_DEVICE_FAMILY = 1;
\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/TripleJump.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/TripleJump";"""

for cid, cname in ((TEST_DEBUG, "Debug"), (TEST_RELEASE, "Release")):
    w("\t\t%s /* %s */ = {" % (cid, cname))
    w("\t\t\tisa = XCBuildConfiguration;")
    w("\t\t\tbuildSettings = {")
    w(TEST_COMMON)
    w("\t\t\t};")
    w("\t\t\tname = %s;" % cname)
    w("\t\t};")
w("/* End XCBuildConfiguration section */")

# XCConfigurationList
w("\n/* Begin XCConfigurationList section */")
for lid, dbg, rel, label in (
        (PROJ_CFG_LIST, PROJ_DEBUG, PROJ_RELEASE, "PBXProject"),
        (APP_CFG_LIST, APP_DEBUG, APP_RELEASE, "PBXNativeTarget \"%s\"" % APP_TARGET),
        (TEST_CFG_LIST, TEST_DEBUG, TEST_RELEASE, "PBXNativeTarget \"%s\"" % TEST_TARGET)):
    w("\t\t%s /* Build configuration list for %s */ = {" % (lid, label))
    w("\t\t\tisa = XCConfigurationList;")
    w("\t\t\tbuildConfigurations = (")
    w("\t\t\t\t%s /* Debug */," % dbg)
    w("\t\t\t\t%s /* Release */," % rel)
    w("\t\t\t);")
    w("\t\t\tdefaultConfigurationIsVisible = 0;")
    w("\t\t\tdefaultConfigurationName = Release;")
    w("\t\t};")
w("/* End XCConfigurationList section */")

w("\t};")
w("\trootObject = %s /* Project object */;" % PROJECT)
w("}")

PROJ.mkdir(parents=True, exist_ok=True)
(PROJ / "project.pbxproj").write_text("\n".join(out) + "\n")

# No shared .xcscheme is written, and scheme autocreation is deliberately left
# on. Xcode derives a working scheme from the targets itself; a hand-written
# one that Xcode declines to accept produces "Scheme ... is not currently
# configured for the build action", which looks like a project problem and is
# not. Autocreation also folds the test target into the app scheme's test
# action, so `xcodebuild test` works with no scheme file at all.

print("wrote", PROJ / "project.pbxproj")
print("app sources:", len(app_sources), "lib sources:", len(lib_sources),
      "test sources:", len(test_sources))
