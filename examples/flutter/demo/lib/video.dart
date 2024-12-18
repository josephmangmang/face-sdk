import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:camera/camera.dart';
import 'package:face_sdk_3divi/face_sdk_3divi.dart';
import 'package:face_sdk_3divi/utils.dart';
import 'package:flutter/material.dart';
import 'package:percent_indicator/linear_percent_indicator.dart';

typedef void setLivenssStatus(bool isPassed, Template templ, Image? img, double mirror);

class VideoProcessing extends StatefulWidget {
  final List<CameraDescription> cameras;
  final FacerecService _facerecService;
  final Recognizer _recognizer;
  final String nextRoute;
  final setLivenssStatus callback;

  VideoProcessing(this.cameras, this._facerecService, this._recognizer, this.nextRoute, this.callback);

  @override
  _VideoProcessingState createState() => _VideoProcessingState();
}

class _VideoProcessingState extends State<VideoProcessing> {
  RawImageF? _ri;
  late CameraController controller;

  late VideoWorker _videoWorker;
  Offset? widgetPosition;
  ui.Size? widgetSize;
  GlobalKey _pictureKey = GlobalKey();
  int _lastImgTimestamp = 0;
  CameraImage? _lastImg;
  Uint8List? bestImage;
  int livenessProgress = 0;
  String activeLivenessAction = " ";
  Template? templ;
  bool _isLivenessSet = false;
  int baseAngle = 0;
  late Rectangle rect;
  double mirror = 0;

  double best_quality = -100000000;
  bool livenessPassed = false;
  bool livenessFailed = false;
  late Stream<int> streamAddVW;
  late Stream<int> streamPoolVW;

  void _processStream(CameraImage img) async {
    if (!mounted) return;
    final RenderBox renderBox = _pictureKey.currentContext?.findRenderObject() as RenderBox;
    widgetPosition = renderBox.localToGlobal(Offset.zero);
    widgetSize = renderBox.size;

    int startTime = DateTime.now().millisecondsSinceEpoch;
    setState(() {
      _lastImgTimestamp = startTime;
      _lastImg = img;
    });
  }

  @override
  void initState() {
    super.initState();
    if (widget.cameras.length < 1) {
      print("No camera is found");
    } else {
      final camera = widget.cameras[1];
      controller = CameraController(camera, ResolutionPreset.high, enableAudio: false);
      controller.initialize().then((_) {
        if (!mounted) {
          return;
        }

        setState(() {});

        controller.startImageStream(_processStream);
      });
    }

    if (controller.description.sensorOrientation == 90) {
      mirror = 1;
    }

    baseAngle = getBaseAngle(controller);

    double apply_horizontal_flip = 0;
    if (Platform.isIOS && controller.description.lensDirection == CameraLensDirection.front) {
      apply_horizontal_flip = 1;
    }

    List<ActiveLivenessCheckType> checks = [
      ActiveLivenessCheckType.TURN_LEFT,
      ActiveLivenessCheckType.SMILE,
      ActiveLivenessCheckType.TURN_DOWN
    ];

    _videoWorker = widget._facerecService.createVideoWorker(VideoWorkerParams()
        .recognizer_ini_file("method12v30_recognizer.xml")
        .video_worker_config(Config("video_worker_fdatracker_blf_fda_front.xml")
            .overrideParameter("enable_active_liveness", 1)
            .overrideParameter("active_liveness.apply_horizontal_flip", apply_horizontal_flip))
        .streams_count(1)
        .processing_threads_count(0)
        .matching_threads_count(0)
        .emotions_estimation_threads_count(1)
        .active_liveness_checks_order(checks));

    Duration interval = Duration(milliseconds: 50);
    streamAddVW = Stream<int>.periodic(interval, addVF);
    streamPoolVW = Stream<int>.periodic(interval, pool);
  }

  Image createCrop() {
    return Image.memory(bestImage!);
  }

  int addVF(int value) {
    if (!mounted) {
      return value;
    }

    final time = _lastImgTimestamp;
    var img = _lastImg;

    if (img != null) {
      _ri = widget._facerecService.createRawImageFromCameraImage(img, baseAngle);
      _videoWorker.addVideoFrame(_ri!, time);
      _ri?.dispose();
    }

    return value;
  }

  RawSample? bestSample; // last best sample
  int trackId = -1; // each person has individual track id

  int pool(int value) {
    if (!mounted) {
      return value;
    }
    final callbackData = _videoWorker.poolTrackResults();
    final rawSamples = callbackData.tracking_callback_data.samples;
    List<dynamic> detections = [];

    var angles;
    if (callbackData.tracking_callback_data.samples.length > 0) {
      for (var i = 0; i < rawSamples.length; i += 1) {
        rect = rawSamples[i].getRectangle();
        angles = rawSamples[i].getAngles();
        detections.add({
          "rect": {"x": rect.x, "y": rect.y, "w": rect.width, "h": rect.height},
          "widget": {"w": widgetSize!.height, "h": widgetSize!.width},
          "picture": {"w": _ri!.width, "h": _ri!.height},
          "offset": {"x": widgetPosition!.dx, "y": widgetPosition!.dy}
        });
      }

      // update bestSample by best quality or if detected different person
      if (best_quality < callbackData.tracking_callback_data.samples_quality[0] ||
          trackId != rawSamples.first.getID()) {
        best_quality = callbackData.tracking_callback_data.samples_quality[0];
        bestImage = rawSamples.first.cutFaceImage(ImageFormatCode.IMAGE_FORMAT_PNG, FaceCutType.FACE_CUT_BASE);
        trackId = rawSamples.first.getID();

        bestSample?.dispose();

        bestSample = rawSamples.first;
      }
    }
    int progress = livenessProgress;
    if (!livenessFailed && !livenessPassed) {
      if (callbackData.tracking_callback_data.samples.length == 1) {
        var status = callbackData.tracking_callback_data.samples_active_liveness_status[0];
        if (status.verdict == ActiveLiveness.WAITING_FACE_ALIGN) {
          activeLivenessAction = 'Please, look at the camera';
          if (angles.yaw > 10)
            activeLivenessAction += ' (turn face →)';
          else if (angles.yaw < -10)
            activeLivenessAction += ' (turn face ←)';
          else if (angles.pitch > 10)
            activeLivenessAction += ' (turn face ↓)';
          else if (angles.pitch < -10) activeLivenessAction += ' (turn face ↑)';
        } else if (status.verdict == ActiveLiveness.CHECK_FAIL) {
          activeLivenessAction = 'Active liveness check FAILED';
          livenessFailed = true;
          _videoWorker.resetTrackerOnStream();
        } else if (status.verdict == ActiveLiveness.ALL_CHECKS_PASSED) {
          activeLivenessAction = 'Active liveness check PASSED';
          livenessPassed = true;
          _videoWorker.resetTrackerOnStream();
        } else if (status.verdict == ActiveLiveness.IN_PROGRESS) {
          if (status.check_type == ActiveLivenessCheckType.BLINK)
            activeLivenessAction = 'Blink';
          else if (status.check_type == ActiveLivenessCheckType.SMILE)
            activeLivenessAction = 'Smile';
          else if (status.check_type == ActiveLivenessCheckType.TURN_DOWN)
            activeLivenessAction = 'Turn face down';
          else if (status.check_type == ActiveLivenessCheckType.TURN_LEFT) {
            activeLivenessAction = 'Turn face left';
          } else if (status.check_type == ActiveLivenessCheckType.TURN_RIGHT) {
            activeLivenessAction = 'Turn face right';
          } else if (status.check_type == ActiveLivenessCheckType.TURN_UP) activeLivenessAction = 'Turn face up';
        } else if (status.verdict == ActiveLiveness.NOT_COMPUTED) activeLivenessAction = 'Active liveness disabled';

        progress = (status.progress_level * 100).toInt();
      } else if (callbackData.tracking_callback_data.samples.length > 1) {
        progress = 0;
        activeLivenessAction = "Leave one face in the frame ";
      } else {
        progress = 0;
        activeLivenessAction = "";
      }
    }

    rawSamples.forEach((element) {
      if (element != bestSample) {
        element.dispose();
      }
    });

    setState(() {
      livenessProgress = progress;

      if (!_isLivenessSet && (livenessFailed || livenessPassed)) {
        templ = widget._recognizer.processing(bestSample!); // create template from last best sample

        if (livenessPassed) {
          widget.callback(true, templ!, createCrop(), mirror);
        }
        if (livenessFailed) {
          widget.callback(false, templ!, createCrop(), mirror);
        }

        _isLivenessSet = true;

        bestSample!.dispose();
      }
    });
    return value;
  }

  Widget bboxDrawer() {
    return Container();
  }

  @override
  Widget build(BuildContext context) {
    if (!controller.value.isInitialized) {
      return Container();
    }
    return PopScope(
        child: Scaffold(
      body: Stack(
        children: [
          Center(
            child: Padding(
                key: _pictureKey,
                child: CameraPreview(controller, child: bboxDrawer()),
                padding: const EdgeInsets.all(1.0)),
          ),
          StreamBuilder(
              stream: streamPoolVW,
              builder: (context, snapshot) {
                return Transform.translate(
                    offset: Offset(0, 100),
                    child: Text(activeLivenessAction, style: TextStyle(fontSize: 20, backgroundColor: Colors.black)));
              }),
          StreamBuilder(
            stream: streamAddVW,
            builder: (context, snapshot) {
              return Text("");
            },
          ),
          Container(
            margin: EdgeInsets.only(left: 30, right: 30),
            alignment: Alignment.bottomCenter,
            child: LinearPercentIndicator(
              //leaner progress bar
              // animation: false,
              // animationDuration: 30,
              lineHeight: 20.0,
              percent: livenessProgress / 100,
              restartAnimation: true,
              center: Text(
                livenessProgress.toString() + "%",
                style: TextStyle(fontSize: 12.0, fontWeight: FontWeight.w600, color: Colors.black),
              ),
              linearStrokeCap: LinearStrokeCap.roundAll,
              progressColor: Colors.blue[400],
              backgroundColor: Colors.grey[300],
            ),
          ),
        ],
      ),
      floatingActionButton: Visibility(
        visible: _isLivenessSet,
        child: FloatingActionButton(
          heroTag: "btn5",
          child: Icon(Icons.navigate_next),
          onPressed: () {
            setState(() {
              Navigator.of(context).pop();
              Navigator.of(context).pushNamed(widget.nextRoute);
            });
          },
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
    ));
  }

  @override
  void dispose() {
    controller.dispose();
    _videoWorker.dispose();
    super.dispose();
  }
}
