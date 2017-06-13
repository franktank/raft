//
//  ViewController.swift
//  raft
//
//  Created by Frank the Tank on 6/12/17.
//  Copyright © 2017 Frank the Tank. All rights reserved.
//

import UIKit
import CocoaAsyncSocket
import SwiftyJSON
// @TODO receive id, make data structure unique? Hash / Dictionary
// @TODO need other udp sockets for unicast send/receive?

class ViewController: UIViewController, GCDAsyncUdpSocketDelegate {
    
    // In future have delimiter be associated with AppendEntries RPC request / response and RequestVotes RPC request / response
    
    var udpMulticastSendSocket : GCDAsyncUdpSocket?
    var udpMulticastReceiveSocket : GCDAsyncUdpSocket?
    // multicast address range 224.0.0.0 to 239.255.255.255
    let multicastIp = "225.1.2.3"
    var sendQueue = DispatchQueue.init(label: "send")
    var receiveQueue = DispatchQueue.init(label: "receive")
    var sendMulticastTimer : Timer?
    var receiveTimer : Timer?
    var receivedText = ""
    
    var udpUnicastSocket : GCDAsyncUdpSocket?
    
    @IBOutlet weak var displayTextView: UITextView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        
        // Setup multicast sockets and communication
        udpMulticastSendSocket = GCDAsyncUdpSocket(delegate: self, delegateQueue: sendQueue)
        udpMulticastReceiveSocket = GCDAsyncUdpSocket(delegate: self, delegateQueue: receiveQueue)
        setupSockets()
        sendMulticastTimer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(self.sendMulticast), userInfo: nil, repeats: true)
        
        // Setup unicast sockets and communication - for RPC responses
        
        
    }
    
    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    
/**
 * Network communication using UDP multicast / unicast
**/
    
    func setupSockets() {
        guard let sendSocket = udpMulticastSendSocket, let receiveSocket = udpMulticastReceiveSocket else {
            print("Setup sockets")
            return
        }
    
        do {
            try sendSocket.bind(toPort: 0)
            try sendSocket.joinMulticastGroup(multicastIp)
            try sendSocket.enableBroadcast(true)
            try receiveSocket.bind(toPort: 2001)
            try receiveSocket.joinMulticastGroup(multicastIp)
            try receiveSocket.beginReceiving()
        } catch {
            print(error)
        }
    }
    
    // Take input?
    func sendMulticast() {
        guard let socket = udpMulticastSendSocket, let address = getIFAddresses()[1].data(using: String.Encoding.utf8), let dataString = UIDevice.current.identifierForVendor!.uuidString
.data(using: String.Encoding.utf8) else {
            print("Stuff could not be initialized")
            return
        }
        let jsonToSend : JSON = [
            "type" : "multicast",
            "message" : getIFAddresses()[1]
        ]
        
        guard let jsonString = jsonToSend.rawString()?.data(using: String.Encoding.utf8) else {
            print("Couldn't create JSON")
            return
        }
        
        socket.send(jsonString, toHost: multicastIp, port: 2001, withTimeout: -1, tag: 0)
    }

    func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        guard let jsonString = String(data: data, encoding: String.Encoding.utf8) else {
            print("Didn't get a string")
            return
        }
        
        var receivedJSON = JSON(data: data)
        let type = receivedJSON["type"].stringValue
        let message = receivedJSON["message"].stringValue
        
        print(type)
        // Check to see how to handle RPC
        
        receivedText = receivedText + " " + message
        DispatchQueue.main.async {
            self.displayTextView.text = self.receivedText
        }

    }
    
    func getIFAddresses() -> [String] {
        var addresses = [String]()
        
        // Get list of all interfaces on the local machine:
        var ifaddr : UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        guard let firstAddr = ifaddr else { return [] }
        
        // For each interface ...
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            
            // Check for running IPv4, IPv6 interfaces. Skip the loopback interface.
            if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                if addr.sa_family == UInt8(AF_INET) || addr.sa_family == UInt8(AF_INET6) {
                    
                    // Convert interface address to a human readable string:
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if (getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count),
                                    nil, socklen_t(0), NI_NUMERICHOST) == 0) {
                        let address = String(cString: hostname)
                        addresses.append(address)
                    }
                }
            }
        }
        
        freeifaddrs(ifaddr)
        return addresses
    }
    
    func setupUnicastSocket() {
        
    }
}

