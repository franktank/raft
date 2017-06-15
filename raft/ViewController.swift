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

class ViewController: UIViewController, GCDAsyncUdpSocketDelegate {
    // 192.168.10.57 192.168.10.58 192.168.10.60
    // In future have delimiter be associated with AppendEntries RPC request / response and RequestVotes RPC request / response
    
    // Multicast socket variables
    var udpMulticastSendSocket : GCDAsyncUdpSocket?
    var udpMulticastReceiveSocket : GCDAsyncUdpSocket?
    let multicastIp = "225.1.2.3" // multicast address range 224.0.0.0 to 239.255.255.255
    var sendQueue = DispatchQueue.init(label: "send")
    var receiveQueue = DispatchQueue.init(label: "receive")
    var unicastQueue = DispatchQueue.init(label: "unicast")
    var sendMulticastTimer : Timer?
    var receiveTimer : Timer?
    var receivedText = ""
    var addressPort = [String: String]() // Be aware of self IP when multicast
    
    // Unicasting variables
    var udpUnicastSocket : GCDAsyncUdpSocket?
    
    //Term variables
    var rpcDue : [String:Date]? // how much time before sending another RPC
    var nextIndex : [String:Int]? // index of next log entry to send to peer
    var voteGranted : [String:Bool]? // true if peer grants vote to current server
    var matchIndex : [String:Int]? // index of highest log entry known to be replicated on peer
    
    // Server variables
    var log : Array<JSON>?
    var currentTerm = 1
    
    let LEADER = 1
    let CANDIDATE = 2
    let FOLLOWER = 3
    var role : Int?
    // Application elements
    let textField = UITextView()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        self.title = "Franky's Raft Demo -- Failing"
        view.backgroundColor = UIColor.white
        
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.textAlignment = .center
        
        
        // Setup multicast sockets and communication
        udpMulticastSendSocket = GCDAsyncUdpSocket(delegate: self, delegateQueue: sendQueue)
        udpMulticastReceiveSocket = GCDAsyncUdpSocket(delegate: self, delegateQueue: receiveQueue)
        setupSockets()
        sendMulticastTimer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(self.sendMulticast), userInfo: nil, repeats: true)
        
        // Setup unicast sockets and communication - for RPC responses
        udpUnicastSocket = GCDAsyncUdpSocket(delegate: self, delegateQueue: unicastQueue)
        setupUnicastSocket()
        sendUnicast()
        
        // Server variables
        role = FOLLOWER
        log = Array<JSON>()
        // log.append(some JSON)
        
    }
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        
        self.view.addSubview(textField)

        let horConstraint = NSLayoutConstraint(item: textField, attribute: .top, relatedBy: .equal,
                                               toItem: view, attribute: .top,
                                               multiplier: 1, constant: 0.0)
        let verConstraint = NSLayoutConstraint(item: textField, attribute: .bottom, relatedBy: .equal,
                                               toItem: view, attribute: .bottom,
                                               multiplier: 1, constant: 0.0)
        let widConstraint = NSLayoutConstraint(item: textField, attribute: .right, relatedBy: .equal,
                                               toItem: view, attribute: .right,
                                               multiplier: 1, constant: 0.0)
        let heiConstraint = NSLayoutConstraint(item: textField, attribute: .left, relatedBy: .equal,
                                               toItem: view, attribute: .left,
                                               multiplier: 1, constant: 0.0)
        NSLayoutConstraint.activate([horConstraint, verConstraint, widConstraint, heiConstraint])
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
        guard let socket = udpMulticastSendSocket else {
            print("Stuff could not be initialized")
            return
        }
        let jsonToSend : JSON = [
            "type" : "multicast",
            "address" : getIFAddresses()[1],
            "port" : "20011"
        ]
        
        guard let jsonString = jsonToSend.rawString()?.data(using: String.Encoding.utf8) else {
            print("Couldn't create JSON")
            return
        }
        
        socket.send(jsonString, toHost: multicastIp, port: 2001, withTimeout: -1, tag: 0)
    }
    
    // Receive multicast and unicast
    func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        guard let jsonString = String(data: data, encoding: String.Encoding.utf8) else {
            print("Didn't get a string")
            return
        }
        
        var receivedJSON = JSON(data: data)
        let type = receivedJSON["type"].stringValue
        let address = receivedJSON["address"].stringValue
        let port = receivedJSON["port"].stringValue
        
        if (type == "multicast") {
           addressPort[receivedJSON["address"].stringValue] = addressPort[receivedJSON["port"].stringValue]
        } else if (type == "unicast") {
            print("YOOOOOOOOOOOOO")
            print(type)
        }
        
        // Check to see how to handle RPC
        
        receivedText = receivedText + " " + address
        DispatchQueue.main.async {
            self.textField.text = self.receivedText
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
        guard let socket = udpUnicastSocket, let address = getIFAddresses()[1].data(using: String.Encoding.utf8) else {
            print("Setup sockets")
            return
        }
        print(getIFAddresses())
        do {
//            try socket.bind(toAddress: address) // Problem here?
            try socket.bind(toPort: 20011)
            try socket.beginReceiving()
        } catch {
            print(error)
        }
    }
    
    func sendUnicast() {
        guard let socket = udpUnicastSocket, let sendString = "UnicastOP".data(using: String.Encoding.utf8) else {
            print("Stuff could not be initialized")
            return
        }
        
        let jsonToSend : JSON = [
            "type" : "unicast",
            "address" : getIFAddresses()[1],
            "port" : "20011"
        ]
        
        guard let jsonString = jsonToSend.rawString()?.data(using: String.Encoding.utf8) else {
            print("Couldn't create JSON")
            return
        }
        socket.send(jsonString, toHost: "192.168.10.58", port: 20011, withTimeout: -1, tag: 0)
    }
    
    func receiveClientMessage(message: String) {
        
    }
    
    func appendEntries(logEntry: JSON) -> JSON {
        
    }
}

