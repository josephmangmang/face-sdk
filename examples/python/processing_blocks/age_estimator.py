import argparse  # for an ArgumentParser
import os.path
import cv2  # for reading images, visualising window and rectangle creation
import numpy as np

from sys import platform  # for a platform identification
from face_sdk_3divi import FacerecService, Config  # FacerecService creates service, Config creates capturer config
from face_sdk_3divi.modules.raw_image import Format, RawImage  # RawImage is a raw image interface, Format specifies the format of image data


def help_message():
    message = f"\n This program is an example of the Age Estimator Processing block integration \n Usage: " \
              " [--input_image <image_path>] " \
              " [--sdk_path <sdk_root_dir>] " \
              " [--use_cuda <--use_cuda>]"
    print(message)


def parse_args():  # launch parameters
    parser = argparse.ArgumentParser(description='Processing Block Example')
    parser.add_argument('--input_image', type=str, required=True)
    parser.add_argument('--sdk_path', default="../../../", type=str)
    parser.add_argument('--use_cuda', action='store_true')  # pass the '--use_cuda' parameter before launch to use cuda acceleration
    return parser.parse_args()


def draw_bbox(rect, img, color=(0, 255, 0)):  # an example of a bbox drawing with opencv
    return cv2.rectangle(img, (int(rect[0] * img.shape[1]), int(rect[1] * img.shape[0])),
                         (int(rect[2] * img.shape[1]), int(rect[3] * img.shape[0])), color, 2)


# capturing faces with a Capturer class object
def capturer_detection(service, img, estimator_block):
    input_rawimg = RawImage(img.shape[1], img.shape[0], Format.FORMAT_BGR, img.tobytes())  # convert an image in Raw Image before passing to capturer

    capturer_config = Config("common_capturer_uld_fda.xml")  # required parameter, sets a name of capturer configuration file as an argument. You can also specify override parameters which are listed in documentation
    capturer = service.create_capturer(capturer_config)  # create capturer object
    samples = capturer.capture(input_rawimg)  # capture faces in an image

    ioData = {"objects": []}  # create container for an output data

    for i, sample in enumerate(samples):  # iteration over detected faces, enumerate is needed to get a sample id
        frame = sample.get_rectangle()  # get a bbox coordinates from sample
        x = frame.x if frame.x > 0 else 0  # restrict coordinates values to non-negative
        y = frame.y if frame.y > 0 else 0
        face_crop = img[y:y + frame.height, x:x + frame.width]  # crop a face

        input_crop: np.ndarray = cv2.cvtColor(face_crop, cv2.COLOR_BGR2RGB)  # convert an image in RGB for correct results
        cropCtx = {  # put cropped image in container
            "blob": input_crop.tobytes(),
            "dtype": "uint8_t",
            "format": "NDARRAY",
            "shape": [dim for dim in input_crop.shape]
        }
        estimatorCtx = {"image": cropCtx}  # put cropCtx in container which will be passed to an estimator block
        estimator_block(estimatorCtx)  # call an estimator and pass a container with a cropped image

        estimatorCtx["objects"][0]["bbox"] = [  # copy bbox coordinates in container to visualize it on image
            float(frame.x / img.shape[1]),
            float(frame.y / img.shape[0]),
            float((frame.x + frame.width) / img.shape[1]),
            float((frame.y + frame.height) / img.shape[0]),
        ]

        estimatorCtx["objects"][0]["id"] = i  # overwrite sample id
        ioData["objects"].append(estimatorCtx["objects"][0])  # copy an estimator output to ioData container

    for obj in ioData["objects"]:  # iteration over objects in ioData container
        print("\n", obj)  # print results in console
        picture = draw_bbox(obj["bbox"], img)  # visualize bboxes on an image

    return picture


# capturing faces with a face detector block
def detector_detection(service, img, estimator_block, sdk_path, sdk_onnx_path):
    detector_config = {  # detector block configuration parameters
        "unit_type": "FACE_DETECTOR",  # required parameter
        "model_path": sdk_path + "/share/facedetectors/face.enc",  # required
        "confidence_threshold": 0.5,  # optional
        "iou_threshold": 0.5,  # optional
        "use_cuda": use_cuda,  # optional
        "ONNXRuntime": {
            "library_path": sdk_onnx_path  # optional
        }
    }
    detector_block = service.create_processing_block(detector_config)  # create detector processing block

    image: np.ndarray = cv2.cvtColor(img, cv2.COLOR_BGR2RGB)  # convert image before passing it to a detector
    imgCtx = {  # put an image in container
        "blob": image.tobytes(),
        "dtype": "uint8_t",
        "format": "NDARRAY",
        "shape": [dim for dim in image.shape]
    }

    detectorCtx = {"image": imgCtx}  # put imgCtx in container which will be passed to a detector block
    detector_block(detectorCtx)  # call detector block and pass a container with an image

    for obj in detectorCtx["objects"]:  # iteration over objects in detectorCtx container
        img_w = img.shape[1]
        img_h = img.shape[0]

        rect = obj["bbox"]  # get a bbox coordinates from a container
        x = int(rect[0] * img_w)
        y = int(rect[1] * img_h)
        width = int(rect[2] * img_w) - x
        height = int(rect[3] * img_h) - y

        face_crop = img[max(0, y - height): min(img_h, y + height),  # crop a face
                    max(0, x - width): min(img_w, x + width)]

        input_crop: np.ndarray = cv2.cvtColor(face_crop, cv2.COLOR_BGR2RGB)  # convert an image in RGB for correct results
        cropCtx = {  # put cropped image in container
            "blob": input_crop.tobytes(),
            "dtype": "uint8_t",
            "format": "NDARRAY",
            "shape": [dim for dim in input_crop.shape]
        }

        estimatorCtx = {"image": cropCtx}  # put cropCtx in container which will be passed to an estimator block
        estimator_block(estimatorCtx)  # call an estimator and pass a container with a cropped image

        print("\n", estimatorCtx['objects'])  # print results in console
        picture = draw_bbox(rect, img)  # visualize bboxes on an image

    return picture


def age_estimator(input_image, sdk_path, use_cuda):
    sdk_conf_dir = os.path.join(sdk_path, 'conf', 'facerec')
    if platform == "win32":  # for Windows
        sdk_dll_path = os.path.join(sdk_path, 'bin', 'facerec.dll')
        sdk_onnx_path = os.path.join(sdk_path, 'bin')
    else:  # for Linux
        sdk_dll_path = os.path.join(sdk_path, 'lib', 'libfacerec.so')
        sdk_onnx_path = os.path.join(sdk_path, 'lib')

    service = FacerecService.create_service(  # create FacerecService
        sdk_dll_path,
        sdk_conf_dir,
        f'{sdk_path}/license')

    age_config = {  # age block configuration parameters
        "unit_type": "AGE_ESTIMATOR",  # required parameter
        "model_path": sdk_path + "/share/faceanalysis/age_heavy.enc",  # required
        "use_cuda": use_cuda,  # optional
        "ONNXRuntime": {
            "library_path": sdk_onnx_path  # optional
        }
    }
    age_block = service.create_processing_block(age_config)  # create age estimation processing block

    img: np.ndarray = cv2.imread(input_image)  # read an image from a file

    # detect, crop and estimate faces in an image, returns an image with a drawn bboxes
    # choose any of two ways
    picture = capturer_detection(service, img, age_block)
    # or
    # picture = detector_detection(service, img, age_block, sdk_path, sdk_onnx_path)

    cv2.imshow("result", picture)  # an example of a result image visualizing with opencv
    cv2.waitKey(0)  # wait for a key to be pressed to close the window
    cv2.destroyAllWindows()  # close the window


if __name__ == "__main__":
    help_message()
    args = parse_args()

    age_estimator(args.input_image, args.sdk_path, args.use_cuda)
