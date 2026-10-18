// Adapted from mstyura/RTCAudioDevice (MIT License).
// Copyright (c) 2022 Yury Yaroshevich.
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation
import CoreAudioTypes
import AVFAudio

public final class BufferedRTCConverter {
  public let from: AVAudioFormat
  public let to: AVAudioFormat
  private var audioConverter: AudioConverterRef?

  public init?(from: AVAudioFormat, to: AVAudioFormat) {
    guard from.sampleRate == to.sampleRate else {
      print("Sample rate conversion is not possible")
      return nil
    }
    guard noErr == AudioConverterNew(from.streamDescription, to.streamDescription, &audioConverter) else {
      return nil
    }
    self.from = from
    self.to = to
  }

  deinit {
    if let audioConverter = audioConverter {
      AudioConverterDispose(audioConverter)
    }
    audioConverter = nil
  }

  public func convert(framesCount: AVAudioFrameCount, from: UnsafePointer<AudioBufferList>, to: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
    guard let audioConverter = audioConverter else {
      preconditionFailure("Not properly inited")
    }
    let status = AudioConverterConvertComplexBuffer(audioConverter, framesCount, from, to)
    return status
  }
}
