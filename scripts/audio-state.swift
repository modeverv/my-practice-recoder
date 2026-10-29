import Foundation
import CoreAudio
func read<T>(_ id:AudioObjectID,_ selector:AudioObjectPropertySelector, initial:T)->T {
 var value=initial; var size=UInt32(MemoryLayout<T>.size)
 var a=AudioObjectPropertyAddress(mSelector:selector,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
 AudioObjectGetPropertyData(id,&a,0,nil,&size,&value); return value
}
let system=AudioObjectID(kAudioObjectSystemObject)
let defaultIn=read(system,kAudioHardwarePropertyDefaultInputDevice,initial:AudioDeviceID(0))
let defaultOut=read(system,kAudioHardwarePropertyDefaultOutputDevice,initial:AudioDeviceID(0))
var a=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
var size:UInt32=0
AudioObjectGetPropertyDataSize(system,&a,0,nil,&size)
var devices=[AudioDeviceID](repeating:0,count:Int(size)/4)
AudioObjectGetPropertyData(system,&a,0,nil,&size,&devices)
var rows=[[String:Any]]()
for d in devices {
 let uid:CFString=read(d,kAudioDevicePropertyDeviceUID,initial:"" as CFString)
 let name:CFString=read(d,kAudioObjectPropertyName,initial:"" as CFString)
 if (uid as String).contains("RME") || d == defaultIn || d == defaultOut {
  rows.append(["uid":uid as String,"name":name as String,"sampleRate":read(d,kAudioDevicePropertyNominalSampleRate,initial:Float64(0)),"bufferFrames":read(d,kAudioDevicePropertyBufferFrameSize,initial:UInt32(0)),"defaultInput":d==defaultIn,"defaultOutput":d==defaultOut])
 }
}
let data=try JSONSerialization.data(withJSONObject:rows.sorted { ($0["uid"] as! String) < ($1["uid"] as! String) },options:[.prettyPrinted,.sortedKeys]); print(String(data:data,encoding:.utf8)!)
