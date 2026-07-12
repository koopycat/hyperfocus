#!/usr/bin/env ruby
require 'securerandom'

PROJECT_DIR = File.expand_path('..', __dir__)
APP_NAME = 'Hyperfocus'
BUNDLE_ID = 'com.hyperfocus.app'
TEAM_ID = '' # Set via xcconfig or leave empty for automatic signing

SRCROOT = PROJECT_DIR
PROJECT_FILE = File.join(SRCROOT, "#{APP_NAME}.xcodeproj", 'project.pbxproj')

# Generate UUIDs
def uuid; SecureRandom.hex(12).upcase; end

project_ref       = uuid
main_group_ref     = uuid
overlay_engine_group = uuid
render_pipeline_group = uuid
app_core_group     = uuid
resources_group    = uuid
products_group     = uuid

app_target_ref     = uuid
build_phases_group = uuid

sources_phase_ref  = uuid
frameworks_phase_ref = uuid
resources_phase_ref = uuid

app_product_ref    = uuid

# Build configs
debug_config_ref   = uuid
release_config_ref = uuid
project_debug_ref  = uuid
project_release_ref = uuid

# Build config list refs
project_config_list = uuid
target_config_list  = uuid

# Files
files = {
  'HyperfocusApp.swift'           => [app_core_group, sources_phase_ref],
  'AppDelegate.swift'             => [app_core_group, sources_phase_ref],
  'OverlayWindowController.swift' => [overlay_engine_group, sources_phase_ref],
  'DisplayManager.swift'          => [overlay_engine_group, sources_phase_ref],
  'ActiveWindowTracker.swift'     => [overlay_engine_group, sources_phase_ref],
  'MouseTracker.swift'           => [overlay_engine_group, sources_phase_ref],
  'StripOverlay.swift'            => [overlay_engine_group, sources_phase_ref],
  'BlurEngine.swift'              => [render_pipeline_group, sources_phase_ref],
  'MetalBlurRenderer.swift'       => [render_pipeline_group, sources_phase_ref],
  'MenuBarController.swift'       => [app_core_group, sources_phase_ref],
  'SettingsView.swift'            => [app_core_group, sources_phase_ref],
  'OnboardingView.swift'          => [app_core_group, sources_phase_ref],
  'Info.plist'                    => [resources_group, resources_phase_ref],
  'Assets.xcassets'               => [resources_group, resources_phase_ref],
}

file_refs = {}
build_file_refs = {}
files.each do |name, _|
  ref = uuid
  file_refs[name] = ref
  build_file_refs[name] = uuid
end

# xcconfig files
debug_xcconfig_ref = uuid
release_xcconfig_ref = uuid

IO.write(PROJECT_FILE, <<~PBXPROJ)
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 56;
	objects = {

/* Begin PBXBuildFile section */
#{build_file_refs.map { |name, ref|
  file_ref = file_refs[name]
  "		#{ref} /* #{name} in #{name.include?('.metal') ? 'Sources' : 'Sources'} */ = {isa = PBXBuildFile; fileRef = #{file_ref} /* #{name} */; };"
}.join("\n")}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		#{project_ref} /* Project object */ = {isa = PBXFileReference; lastKnownFileType = "wrapper.pb-project"; path = "#{APP_NAME}.xcodeproj"; sourceTree = "<group>"; };
		#{app_product_ref} /* #{APP_NAME}.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "#{APP_NAME}.app"; sourceTree = BUILT_PRODUCTS_DIR; };
		#{debug_xcconfig_ref} /* Debug.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Debug.xcconfig; sourceTree = "<group>"; };
		#{release_xcconfig_ref} /* Release.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = Release.xcconfig; sourceTree = "<group>"; };
#{file_refs.map { |name, ref|
  type = case File.extname(name)
         when '.swift' then 'sourcecode.swift'
         when '.metal' then 'sourcecode.metal'
         when '.plist'  then 'text.plist.xml'
         when '.xcassets' then 'folder.assetcatalog'
         else 'file'
         end
  "		#{ref} /* #{name} */ = {isa = PBXFileReference; lastKnownFileType = #{type}; path = \"#{name}\"; sourceTree = \"<group>\"; };"
}.join("\n")}
/* End PBXFileReference section */

/* Begin PBXGroup section */
		#{main_group_ref} = {
			isa = PBXGroup;
			children = (
				#{overlay_engine_group} /* OverlayEngine */,
				#{render_pipeline_group} /* RenderPipeline */,
				#{app_core_group} /* AppCore */,
				#{resources_group} /* Resources */,
				#{products_group} /* Products */,
			);
			path = "#{APP_NAME}";
			sourceTree = "<group>";
		};
		#{overlay_engine_group} /* OverlayEngine */ = {
			isa = PBXGroup;
			children = (
				#{file_refs['OverlayWindowController.swift']} /* OverlayWindowController.swift */,
				#{file_refs['DisplayManager.swift']} /* DisplayManager.swift */,
				#{file_refs['ActiveWindowTracker.swift']} /* ActiveWindowTracker.swift */,
				#{file_refs['MouseTracker.swift']} /* MouseTracker.swift */,
				#{file_refs['StripOverlay.swift']} /* StripOverlay.swift */,
			path = OverlayEngine;
			sourceTree = "<group>";
		};
		#{render_pipeline_group} /* RenderPipeline */ = {
			isa = PBXGroup;
			children = (
				#{file_refs['BlurEngine.swift']} /* BlurEngine.swift */,
				#{file_refs['MetalBlurRenderer.swift']} /* MetalBlurRenderer.swift */,
			);
			path = RenderPipeline;
			sourceTree = "<group>";
		};
		#{app_core_group} /* AppCore */ = {
			isa = PBXGroup;
			children = (
				#{file_refs['HyperfocusApp.swift']} /* HyperfocusApp.swift */,
				#{file_refs['AppDelegate.swift']} /* AppDelegate.swift */,
				#{file_refs['MenuBarController.swift']} /* MenuBarController.swift */,
				#{file_refs['SettingsView.swift']} /* SettingsView.swift */,
				#{file_refs['OnboardingView.swift']} /* OnboardingView.swift */,
				#{debug_xcconfig_ref} /* Debug.xcconfig */,
				#{release_xcconfig_ref} /* Release.xcconfig */,
			);
			path = AppCore;
			sourceTree = "<group>";
		};
		#{resources_group} /* Resources */ = {
			isa = PBXGroup;
			children = (
				#{file_refs['Info.plist']} /* Info.plist */,
				#{file_refs['Assets.xcassets']} /* Assets.xcassets */,
			);
			path = Resources;
			sourceTree = "<group>";
		};
		#{products_group} /* Products */ = {
			isa = PBXGroup;
			children = (
				#{app_product_ref} /* #{APP_NAME}.app */,
			);
			name = Products;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		#{app_target_ref} /* #{APP_NAME} */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = #{target_config_list} /* Build configuration list for PBXNativeTarget "#{APP_NAME}" */;
			buildPhases = (
				#{sources_phase_ref} /* Sources */,
				#{frameworks_phase_ref} /* Frameworks */,
				#{resources_phase_ref} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = "#{APP_NAME}";
			productName = "#{APP_NAME}";
			productReference = #{app_product_ref} /* #{APP_NAME}.app */;
			productType = "com.apple.product-type.application";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		#{project_ref} /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 1530;
				LastUpgradeCheck = 1530;
				TargetAttributes = {
					#{app_target_ref} = {
						CreatedOnToolsVersion = 15.3;
					};
				};
			};
			buildConfigurationList = #{project_config_list} /* Build configuration list for PBXProject "#{APP_NAME}" */;
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = #{main_group_ref};
			productRefGroup = #{products_group} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				#{app_target_ref} /* #{APP_NAME} */,
			);
		};
/* End PBXProject section */

/* Begin PBXSourcesBuildPhase section */
		#{sources_phase_ref} /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
#{files.select { |name, _| ['.swift', '.metal'].include?(File.extname(name)) }.map { |name, _|
  "				#{build_file_refs[name]} /* #{name} in Sources */,"
}.join("\n")}
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin PBXFrameworksBuildPhase section */
		#{frameworks_phase_ref} /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXResourcesBuildPhase section */
		#{resources_phase_ref} /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
				#{build_file_refs['Assets.xcassets']} /* Assets.xcassets in Resources */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		#{project_debug_ref} /* Debug */ = {
			isa = XCBuildConfiguration;
			baseConfigurationReference = #{debug_xcconfig_ref} /* Debug.xcconfig */;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				IPHONEOS_DEPLOYMENT_TARGET = 17.4;
				LOCALIZATION_PREFERS_STRING_CATALOGS = YES;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				MTL_FAST_MATH = YES;
				ONLY_ACTIVE_ARCH = YES;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			};
			name = Debug;
		};
		#{project_release_ref} /* Release */ = {
			isa = XCBuildConfiguration;
			baseConfigurationReference = #{release_xcconfig_ref} /* Release.xcconfig */;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS = YES;
				CLANG_ANALYZER_NONNULL = YES;
				CLANG_CXX_LANGUAGE_STANDARD = "gnu++20";
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_USER_SCRIPT_SANDBOXING = YES;
				GCC_OPTIMIZATION_LEVEL = s;
				IPHONEOS_DEPLOYMENT_TARGET = 17.4;
				LOCALIZATION_PREFERS_STRING_CATALOGS = YES;
				MTL_ENABLE_DEBUG_INFO = NO;
				MTL_FAST_MATH = YES;
				SWIFT_COMPILATION_MODE = wholemodule;
			};
			name = Release;
		};
		#{debug_config_ref} /* Debug */ = {
			isa = XCBuildConfiguration;
			baseConfigurationReference = #{debug_xcconfig_ref} /* Debug.xcconfig */;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = Hyperfocus/Resources/Info.plist;
				INFOPLIST_KEY_LSBackgroundOnly = YES;
				INFOPLIST_KEY_NSHumanReadableCopyright = "";
				INFOPLIST_KEY_NSMainStoryboardFile = "";
				INFOPLIST_KEY_NSPrincipalClass = "";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = "#{BUNDLE_ID}";
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		#{release_config_ref} /* Release */ = {
			isa = XCBuildConfiguration;
			baseConfigurationReference = #{release_xcconfig_ref} /* Release.xcconfig */;
			buildSettings = {
				ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = Hyperfocus/Resources/Info.plist;
				INFOPLIST_KEY_LSBackgroundOnly = YES;
				INFOPLIST_KEY_NSHumanReadableCopyright = "";
				INFOPLIST_KEY_NSMainStoryboardFile = "";
				INFOPLIST_KEY_NSPrincipalClass = "";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = "#{BUNDLE_ID}";
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		#{project_config_list} /* Build configuration list for PBXProject "#{APP_NAME}" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				#{project_debug_ref} /* Debug */,
				#{project_release_ref} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		#{target_config_list} /* Build configuration list for PBXNativeTarget "#{APP_NAME}" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				#{debug_config_ref} /* Debug */,
				#{release_config_ref} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */
	};
	rootObject = #{project_ref} /* Project object */;
}
PBXPROJ

puts "✅ Created #{APP_NAME}.xcodeproj"
