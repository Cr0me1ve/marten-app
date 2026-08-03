import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract class Constants {
  static const appName = "Marten";
  static const githubUrl = "https://github.com/Cr0me1ve/marten-app";
  static const licenseUrl = "https://github.com/Cr0me1ve/marten-app/blob/main/LICENSE.md";
  static const githubReleasesApiUrl = "https://api.github.com/repos/Cr0me1ve/marten-app/releases";
  static const githubLatestReleaseUrl = "https://github.com/Cr0me1ve/marten-app/releases/latest";
  static const appCastUrl = "https://raw.githubusercontent.com/Cr0me1ve/marten-app/main/appcast.xml";
  static const privacyPolicyUrl = "https://github.com/Cr0me1ve/marten-app#privacy";
  static const termsAndConditionsUrl = "https://github.com/Cr0me1ve/marten-app/blob/main/LICENSE.md";
}

const kAnimationDuration = Duration(milliseconds: 250);

abstract class AddProfileModalConst {
  static const fixBtnsGap = 16.0;
  static const fixBtnsGapCount = 4;
  static const fixBtnsItemCount = 3;
  static const navBarGap = 16.0;
  static const navBarBottomGap = 4.0;
  //switch default height
  static const navBarcontentHeight = 32.0;
  static const navBarHeight = navBarGap + navBarBottomGap + navBarcontentHeight;
}

abstract class AlertDialogConst {
  static const minWidth = 280.0;
  static const maxWidth = 560.0;
  static const boxConstraints = BoxConstraints(minWidth: minWidth, maxWidth: maxWidth);
}

abstract class BottomSheetConst {
  static const maxWidth = 456.0;
  static const boxConstraints = BoxConstraints(maxWidth: maxWidth);
  static const borderRadius = BorderRadius.vertical(top: Radius.circular(32));
}

abstract class ProfileTileConst {
  static const radius = Radius.circular(16);
  static const cardBorderRadius = BorderRadius.all(radius);
  static const borderRadiusRight = BorderRadius.horizontal(right: radius);
  static const borderRadiusLeft = BorderRadius.horizontal(left: radius);
  static BorderRadius startBorderRadius(TextDirection direction) =>
      direction == TextDirection.ltr ? borderRadiusLeft : borderRadiusRight;
  static BorderRadius endBorderRadius(TextDirection direction) =>
      direction == TextDirection.ltr ? borderRadiusRight : borderRadiusLeft;
}

abstract class IntroConst {
  static const maxwidth = 620;
  static const termsAndConditionsKey = 'terms-and-conditions';
  static const githubKey = 'github';
  static const licenseKey = 'license';
  static const url = <String, String>{
    IntroConst.termsAndConditionsKey: Constants.termsAndConditionsUrl,
    IntroConst.githubKey: Constants.githubUrl,
    IntroConst.licenseKey: Constants.licenseUrl,
  };
}

abstract class KeyboardConst {
  static final allArrows = {
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
  };
  static final horizontalArrows = {LogicalKeyboardKey.arrowLeft, LogicalKeyboardKey.arrowRight};
  static final verticalArrows = {LogicalKeyboardKey.arrowUp, LogicalKeyboardKey.arrowDown};
  static final select = {LogicalKeyboardKey.select, LogicalKeyboardKey.enter, LogicalKeyboardKey.tab};
}
