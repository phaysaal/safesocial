import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// A QR code with a fixed footprint.
///
/// `QrImageView` sizes itself with a `LayoutBuilder`, and a `LayoutBuilder`
/// cannot answer an intrinsic-size question. An `AlertDialog` asks its
/// content exactly that, so a bare `QrImageView` in a dialog threw during
/// layout and the dialog drew nothing but its barrier (the sphere invite
/// dialog, seen on a phone on 12 October 2026). A tight box answers the
/// question itself and never asks the code.
class QrBox extends StatelessWidget {
  final String data;
  final double size;
  final double padding;

  const QrBox({super.key, required this.data, this.size = 180, this.padding = 8});

  @override
  Widget build(BuildContext context) {
    final side = size + 2 * padding;
    return SizedBox(
      width: side,
      height: side,
      child: Container(
        padding: EdgeInsets.all(padding),
        color: Colors.white,
        child: QrImageView(data: data, size: size, backgroundColor: Colors.white),
      ),
    );
  }
}
