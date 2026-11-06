# UI-test fixture credits

| File | Source | Licence |
|---|---|---|
| street_coat_boots.jpg | https://commons.wikimedia.org/wiki/File:Street_Style_of_2018_2019_in_Tehran_6.jpg (downscaled to 1280 px) | CC0 1.0 |

CI adds this photo to the simulator's photo library (`xcrun simctl addmedia`) so
`test04_ImportGalleryPhotoExtractsItems` can pick it through the real gallery picker.

The real-first-run library (`RealFirstRunE2ETests`) is not stored here: CI builds it with
`scripts/ui_test_library.swift` from the CC0 1.0 photos in `StyleMateTests/Fixtures/photos` (see the
CREDITS.md there): crops, scales and mirrors of `kurta_dhoti_turban.jpg` as the user, the other
photos once each as strangers, plus filler images the script draws itself. The selfie hook
(`-uiTestSelfieFixture`) frames the face in the app's bundled sample of that same CC0 photo.
