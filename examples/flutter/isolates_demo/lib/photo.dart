import 'dart:ui';
import 'dart:io';
import 'dart:async';
import "dart:typed_data";
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:face_sdk_3divi/face_sdk_3divi.dart';
import 'package:face_sdk_3divi/utils.dart';
import 'package:image/image.dart' as image_lib;

import 'bndbox.dart';

void logError(String code, String message) {
  if (message != null) {
    print('Error: $code\nError Message: $message');
  } else {
    print('Error: $code');
  }
}

typedef void SetTemplate(Context template, Image photo);

class DetectPicture extends StatefulWidget {
  final List<CameraDescription> cameras;
  final FacerecService _service;
  final AsyncProcessingBlock templateExtractor;
  final AsyncProcessingBlock qaa;

  final SetTemplate callback;
  final String description;
  final String nextRoute;

  DetectPicture(
      this.cameras, this._service, this.templateExtractor, this.description, this.nextRoute, this.callback, this.qaa);

  @override
  _DetectPictureState createState() => new _DetectPictureState();
}

class _DetectPictureState extends State<DetectPicture> {
  late CameraController controller;
  bool isDetecting = false;
  AsyncCapturer? _capturer;
  Image? _lastImage;
  late Image _cropImg;
  late var fornatal;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  GlobalKey _pictureKey = GlobalKey();
  Offset widgetPosition = Offset(0, 0);
  double widthPreviewImage = 0;
  double heightPreviewImage = 0;
  Size? widgetSize;
  int currentCameraIndex = -1;
  bool hasTemplate = false;
  List<dynamic> _recognitions = [];
  final image_lib.JpegDecoder decoder = image_lib.JpegDecoder();

  void showInSnackBar(String message) {
    // ignore: deprecated_member_use
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      behavior: SnackBarBehavior.floating,
    ));
  }

  Future<XFile?> takePicture() async {
    final CameraController cameraController = controller;
    if (cameraController == null || !cameraController.value.isInitialized) {
      showInSnackBar('Error: select a camera first.');
      return null;
    }

    if (cameraController.value.isTakingPicture) {
      // A capture is already pending, do nothing.
      return null;
    }

    try {
      XFile file = await cameraController.takePicture();
      return file;
    } on CameraException catch (e) {
      _showCameraException(e);
      return null;
    }
  }

  void onTakePictureButtonPressed() {
    final RenderBox renderBox = _pictureKey.currentContext?.findRenderObject() as RenderBox;
    widgetPosition = renderBox.localToGlobal(Offset.zero);
    widgetSize = renderBox.size;

    takePicture().then((XFile? file) async {
      if (mounted) {
        if (file != null && _capturer != null) {
          final Uint8List imageBytes = File(file.path).readAsBytesSync();
          _lastImage = Image.memory(imageBytes);
          var img = await decodeImageFromList(imageBytes);

          List<RawSample> rss = await _capturer!.capture(imageBytes);

          List<dynamic> dets = [];
          if (rss.isNotEmpty) {
            for (var i = 0; i < rss.length; i += 1) {
              final rect = rss[i].getRectangle();

              widthPreviewImage = widgetSize!.width < img.width ? widgetSize!.width : img.width.toDouble();
              heightPreviewImage = widgetSize!.height < img.height ? widgetSize!.height : img.height.toDouble();

              dets.add({
                "rect": {"x": rect.x, "y": rect.y, "w": rect.width, "h": rect.height},
                "widget": {"w": widthPreviewImage, "h": heightPreviewImage},
                "picture": {"w": img.width, "h": img.height}
              });
              _cropImg = await cutFaceFromImageBytes(imageBytes, rect);
              if (rss.length == 1) {
                final ImageDescriptor descriptor =
                    await ImageDescriptor.encoded(await ImmutableBuffer.fromUint8List(imageBytes));

                Context data = widget._service.createContext({
                  "objects": [],
                  "image": {
                    "blob": decoder.decodeImage(imageBytes)!.getBytes(format: image_lib.Format.rgb),
                    "dtype": "uint8_t",
                    "format": "NDARRAY",
                    "shape": [descriptor.height, descriptor.width, 3]
                  }
                });

                data["objects"].pushBack(rss[0].toContext());

                Context object = data["objects"][0];

                await widget.qaa.process(data);

                if (object["quality"]["total_score"].get_value() < 0.5) {
                  showInSnackBar("Low quality score: ${object["quality"]["total_score"].get_value()}");

                  data.dispose();
                  rss.first.dispose();

                  return;
                }

                await widget.templateExtractor.process(data);

                widget.callback(widget._service.createContext(object["template"]), _cropImg);

                hasTemplate = true;

                controller.dispose();
                data.dispose();
              }

              rss[i].dispose();
            }
            if (rss.length > 1) {
              showInSnackBar("Photo will be skipped (for verification), because multiple faces detected");
              _lastImage = null;
            }
            setState(() {
              _recognitions = dets;
            });
          } else
            showInSnackBar("No faces found in the image");
        }
        if (file != null) File(file.path).delete();
      }
    });
  }

  void _showCameraException(CameraException e) {
    logError(e.code, e.description!);
    showInSnackBar('Error: ${e.code}\n${e.description}');
  }

  void changeCamera() {
    currentCameraIndex += 1;
    currentCameraIndex %= math.min(2, widget.cameras.length);
    controller = new CameraController(
      widget.cameras[currentCameraIndex],
      ResolutionPreset.high,
    );

    controller.initialize().then((_) {
      if (!mounted) {
        return;
      }
      setState(() {});
    });
  }

  @override
  void initState() {
    super.initState();
    widget._service.createAsyncCapturer(Config("common_capturer_blf_fda_front.xml")).then((value) => _capturer = value);

    if (widget.cameras == null || widget.cameras.length < 1) {
      print('No camera is found');
    } else {
      changeCamera();
    }
  }

  Widget livePreview(BuildContext context) {
    return Scaffold(
        key: _scaffoldKey,
        appBar: AppBar(
          title: Text(widget.description),
        ),
        body: Column(
          children: <Widget>[
            Expanded(
              child: Center(
                child: Padding(
                    child: CameraPreview(
                      controller,
                      child: Text(
                        " ",
                        key: _pictureKey,
                      ),
                    ),
                    padding: const EdgeInsets.all(1.0)),
              ),
            ),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, mainAxisSize: MainAxisSize.max, children: <Widget>[
              FloatingActionButton(
                heroTag: "btn1",
                child: Icon(Icons.camera_alt),
                // color: Colors.blue,
                onPressed: controller.value.isInitialized ? onTakePictureButtonPressed : null,
              ),
              FloatingActionButton(
                heroTag: "btn2",
                child: const Icon(Icons.flip_camera_android),
                // color: Colors.blue,
                onPressed: controller.value.isInitialized
                    ? () {
                        changeCamera();
                      }
                    : null,
              ),
            ])
          ],
        ));
  }

  Widget imagePreview(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: const Text("Detected faces"),
      ),
      body: Column(
        children: <Widget>[
          Expanded(
            child: Padding(
                child: Stack(
                  children: [
                    Center(
                      child: Container(
                          width: widthPreviewImage,
                          height: heightPreviewImage,
                          margin: const EdgeInsets.only(top: 0),
                          child: Center(child: _lastImage)),
                    ),
                    Center(
                      child: Container(
                        width: widthPreviewImage,
                        height: heightPreviewImage,
                        margin: const EdgeInsets.only(top: 0),
                        child: BndBox(
                          _recognitions,
                          widgetPosition.dx,
                          widgetPosition.dy,
                        ),
                      ),
                    ),
                  ],
                ),
                padding: const EdgeInsets.all(1.0)),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        heroTag: "btn3",
        child: hasTemplate ? Icon(Icons.navigate_next) : Icon(Icons.settings_backup_restore),
        // color: Colors.blue,
        onPressed: () {
          setState(() {
            _recognitions = [];
            if (hasTemplate) {
              Navigator.of(context).pop();
              Navigator.of(context).pushNamed(widget.nextRoute);
            }
          });
        },
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (controller == null || !controller.value.isInitialized) {
      return Container();
    }
    return _lastImage == null ? livePreview(context) : imagePreview(context);
  }

  @override
  void dispose() {
    controller.dispose();
    _capturer?.dispose();
    super.dispose();
  }
}
