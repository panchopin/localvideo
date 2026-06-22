import cv2
import time
import sys

url = "rtsp://192.168.0.163:8554/brcam"

# Tell OpenCV to use TCP and low latency flags
import os
os.environ["OPENCV_FFMPEG_CAPTURE_OPTIONS"] = "rtsp_transport;tcp|fflags;nobuffer|flags;low_delay"

cap = cv2.VideoCapture(url, cv2.CAP_FFMPEG)
if not cap.isOpened():
    print("Failed to open")
    sys.exit(1)

frames = 0
start = time.time()
while True:
    ret, frame = cap.read()
    if not ret:
        break
    frames += 1
    if frames % 30 == 0:
        fps = frames / (time.time() - start)
        print(f"FPS: {fps:.2f}")
    
    cv2.imshow("Test", cv2.resize(frame, (640, 360)))
    if cv2.waitKey(1) & 0xFF == ord('q'):
        break

cap.release()
cv2.destroyAllWindows()
