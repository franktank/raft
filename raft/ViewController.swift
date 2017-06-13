//
//  ViewController.swift
//  raft
//
//  Created by Frank the Tank on 6/12/17.
//  Copyright © 2017 Frank the Tank. All rights reserved.
//

import UIKit
import CocoaAsyncSocket

class ViewController: UIViewController, GCDAsyncUdpSocketDelegate {
    var udpSendSocket : GCDAsyncUdpSocket?
    var udpReceiveSocket : GCDAsyncUdpSocket?
    // multicast address range 224.0.0.0 to 239.255.255.255
    let multicastIp = "225.1.2.3"
    var sendQueue = DispatchQueue.init(label: "send")
    var receiveQueue = DispatchQueue.init(label: "receive")
    var sendTimer : Timer?
    var receiveTimer : Timer?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        
        udpSendSocket = GCDAsyncUdpSocket(delegate: self, delegateQueue: sendQueue)
        udpReceiveSocket = GCDAsyncUdpSocket(delegate: self, delegateQueue: receiveQueue)
        setupSockets()
        sendTimer = Timer.scheduledTimer(timeInterval: 0.3, target: self, selector: #selector(self.sendMulticast), userInfo: nil, repeats: true)
    }
    
    func setupSockets() {
        guard let sendSocket = udpSendSocket, let receiveSocket = udpReceiveSocket else {
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

    func sendMulticast() {
        guard let socket = udpSendSocket, let dataStringz = "Local_IP".data(using: String.Encoding.utf8) else {
            print("Stuff could not be initialized")
            return
        }
        

        socket.send(dataStringz, toHost: multicastIp, port: 2001, withTimeout: -1, tag: 0)

    }

    
    func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        print(String(data: data, encoding: String.Encoding.utf8) ?? "Nothing")
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }
    

}

