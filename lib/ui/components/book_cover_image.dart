// Dart imports:
import 'dart:io';

// Flutter imports:
import 'package:flutter/material.dart';

// Package imports:
import 'package:cached_network_image/cached_network_image.dart';

/// Renders a book cover from either a network URL (Anna's Archive / Open
/// Library thumbnails) or a local file path (covers extracted from the book
/// file itself). Falls back to a colored placeholder.
class BookCoverImage extends StatelessWidget {
  const BookCoverImage({
    super.key,
    required this.source,
    required this.height,
    required this.width,
    required this.borderRadius,
    required this.placeholderColor,
  });

  final String? source;
  final double height;
  final double width;
  final double borderRadius;
  final Color placeholderColor;

  bool get _isLocal =>
      source != null &&
      (source!.startsWith('/') || source!.startsWith('file://'));

  Widget _framed(ImageProvider imageProvider) {
    return Container(
      height: height,
      width: width,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.all(Radius.circular(borderRadius)),
        image: DecorationImage(
          image: imageProvider,
          fit: BoxFit.fill,
        ),
      ),
    );
  }

  Widget _placeholder({bool withIcon = false}) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        color: placeholderColor,
      ),
      height: height,
      width: width,
      child: withIcon ? const Center(child: Icon(Icons.image_rounded)) : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLocal) {
      final path = source!.startsWith('file://')
          ? source!.substring('file://'.length)
          : source!;
      final file = File(path);
      if (file.existsSync()) {
        return _framed(FileImage(file));
      }
      return _placeholder(withIcon: true);
    }

    if (source == null || source!.isEmpty) {
      return _placeholder(withIcon: true);
    }

    return CachedNetworkImage(
      height: height,
      width: width,
      imageUrl: source!,
      imageBuilder: (context, imageProvider) => _framed(imageProvider),
      placeholder: (context, url) => _placeholder(),
      errorWidget: (context, url, error) => _placeholder(withIcon: true),
    );
  }
}
