// Data symbols from iOS 15/16 frameworks. Bound to the shim by patch.py instead of
// weak-null: a null data import crashes on first read (and a nil key in a dictionary
// literal throws). Values are the strings the newer SDKs use where known; for keys a
// 14 framework doesn't understand, any distinct string is harmless (ignored key).

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

#define EXPORT __attribute__((visibility("default")))
#define STR(name, value) EXPORT NSString *const name = @value;
#define CFSTR_(name, value) EXPORT const CFStringRef name = CFSTR(value);

// Foundation
STR(NSDetailedErrorsKey, "NSDetailedErrors")
STR(NSMultipleUnderlyingErrorsKey, "NSMultipleUnderlyingErrorsKey")

// UIKit
STR(UIApplicationOpenURLOptionsEventAttributionKey, "UIApplicationOpenURLOptionsEventAttributionKey")
STR(UIApplicationOpenDefaultApplicationsSettingsURLString, "app-settings:")
// iOS 15 Swift-facing names for the CoreText feature keys UIKit already uses
STR(UIFontFeatureTypeIdentifierKey_ForNewSwiftAPI, "CTFeatureTypeIdentifier")
STR(UIFontFeatureSelectorIdentifierKey_ForNewSwiftAPI, "CTFeatureSelectorIdentifier")
STR(UIKeyInputDelete, "\b")
STR(UIMenuSidebar, "com.apple.menu.sidebar")
STR(UISheetPresentationControllerDetentIdentifierLarge, "com.apple.UIKit.large")
STR(UISheetPresentationControllerDetentIdentifierMedium, "com.apple.UIKit.medium")
STR(UITextContentTypeDateTime, "dateTime")

// AVFAudio (14.5)
STR(AVAudioSessionInterruptionReasonKey, "AVAudioSessionInterruptionReasonKey")

// AuthenticationServices
STR(ASAuthorizationPublicKeyCredentialUserVerificationPreferenceRequired, "required")
STR(ASAuthorizationPublicKeyCredentialUserVerificationPreferencePreferred, "preferred")
STR(ASAuthorizationPublicKeyCredentialUserVerificationPreferenceDiscouraged, "discouraged")

// StoreKit ad attribution (16.1)
STR(SKANErrorDomain, "SKANErrorDomain")
STR(SKAdNetworkCoarseConversionValueHigh, "high")
STR(SKAdNetworkCoarseConversionValueMedium, "medium")
STR(SKAdNetworkCoarseConversionValueLow, "low")
STR(SKStoreProductParameterCustomProductPageIdentifier, "customProductPageIdentifier")

// CoreVideo / ImageIO
CFSTR_(kCVImageBufferAmbientViewingEnvironmentKey, "AmbientViewingEnvironment")
CFSTR_(kCGImagePropertyGroups, "Groups")
CFSTR_(kCGImagePropertyGroupType, "GroupType")
CFSTR_(kCGImagePropertyGroupTypeStereoPair, "StereoPair")

// VideoToolbox: newer encoder keys are rejected by 14's encoder (kVTPropertyNotSupportedErr,
// callers treat as optional). The constrained H.264 profiles don't exist on 14: map to the
// closest profile 14 accepts, so session setup doesn't fail outright.
CFSTR_(kVTCompressionPropertyKey_BaseLayerBitRateFraction, "BaseLayerBitRateFraction")
CFSTR_(kVTCompressionPropertyKey_BaseLayerFrameRateFraction, "BaseLayerFrameRateFraction")
CFSTR_(kVTCompressionPropertyKey_EnableLTR, "EnableLTR")
CFSTR_(kVTCompressionPropertyKey_MaxAllowedFrameQP, "MaxAllowedFrameQP")
CFSTR_(kVTEncodeFrameOptionKey_AcknowledgedLTRTokens, "AcknowledgedLTRTokens")
CFSTR_(kVTEncodeFrameOptionKey_ForceLTRRefresh, "ForceLTRRefresh")
CFSTR_(kVTSampleAttachmentKey_RequireLTRAcknowledgementToken, "RequireLTRAcknowledgementToken")
CFSTR_(kVTVideoEncoderSpecification_EnableLowLatencyRateControl, "EnableLowLatencyRateControl")
CFSTR_(kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel, "H264_Baseline_AutoLevel")
CFSTR_(kVTProfileLevel_H264_ConstrainedHigh_AutoLevel, "H264_High_AutoLevel")

// QuartzCore: CAFrameRateRangeDefault = {0, 0, 0}
EXPORT const struct { float minimum, maximum, preferred; } CAFrameRateRangeDefault = {0, 0, 0};
