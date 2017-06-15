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

class ViewController: UIViewController, GCDAsyncUdpSocketDelegate {
    // 192.168.10.57 192.168.10.58 192.168.10.60
    
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
    var rpcDue = [String:Date]() // how much time before sending another RPC
    var nextIndex = [String:Int]() // index of next log entry to send to peer
    var voteGranted = [String:Bool]() // true if peer grants vote to current server
    var matchIndex = [String:Int]() // index of highest log entry known to be replicated on peer
    var leaderIp : String?
    
    // Server variables
    var cluster = ["192.168.10.57", "192.168.10.58", "192.168.10.60"]
    var log = [JSON]()
    var currentTerm = 1
    var commitIndex = 0
    
    let LEADER = 1
    let CANDIDATE = 2
    let FOLLOWER = 3
    var role : Int?
    // Application elements
    @IBOutlet weak var logTextField: UITextView!
    @IBOutlet weak var inputTextField: UITextField!
    @IBOutlet weak var roleLabel: UILabel!
    
    
    @IBAction func editInput(_ sender: Any) {
        guard let msg = inputTextField.text else {
            print("No message")
            return
        }
        receiveClientMessage(message: msg)
    }
    
    func updateRoleLabel() {
        DispatchQueue.main.async {
            if (self.role == self.FOLLOWER) {
                self.roleLabel.text = "FOLLOWER"
            } else if (self.role == self.CANDIDATE) {
                self.roleLabel.text = "CANDIDATE"
            } else if (self.role == self.LEADER) {
                self.roleLabel.text = "LEADER"
            }
        }
    }
    
    func updateLogTextField() {
        DispatchQueue.main.async {
            var displayText = ""
            for element in self.log {
                displayText = displayText + " " + element["message"].stringValue
            }
            self.logTextField.text = displayText
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Setup multicast sockets and communication
        udpMulticastSendSocket = GCDAsyncUdpSocket(delegate: self, delegateQueue: sendQueue)
        udpMulticastReceiveSocket = GCDAsyncUdpSocket(delegate: self, delegateQueue: receiveQueue)
        setupSockets()
//        sendMulticastTimer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(self.sendMulticast), userInfo: nil, repeats: true)
        
        // Setup unicast sockets and communication - for RPC responses
        udpUnicastSocket = GCDAsyncUdpSocket(delegate: self, delegateQueue: unicastQueue)
        setupUnicastSocket()

        // Server variables
        leaderIp = "192.168.10.57"
        role = LEADER // Appending entries should revert people to follower
        updateRoleLabel()
        
        // ???
        // leaderInit() or something
        for server in cluster {
//            if (log.count > 0) {
//                nextIndex[server] = log.count - 1
//            } else {
//                nextIndex[server] = 0
//            }
            print("Initial log count" + String(log.count))
            nextIndex[server] = (log.count) // last log INDEX + 1
            matchIndex[server] = 0
        }
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
    
    func stepDown(term: Int) {
        role = FOLLOWER
        updateRoleLabel()
        currentTerm = term
        // Need votedFor and resetTimer()
    }
    
    // Receive multicast and unicast
    func udpSocket(_ sock: GCDAsyncUdpSocket, didReceive data: Data, fromAddress address: Data, withFilterContext filterContext: Any?) {
        var receivedJSON = JSON(data: data)
        let type = receivedJSON["type"].stringValue
        
        if (type == "redirect") {
            // Handle redirecting message to leader
            
            let msg = receivedJSON["message"].stringValue
            receiveClientMessage(message: msg)
        } else if (type == "appendEntriesRequest") {
            // Handle append entries request
            
            print("Received appendEntriesRequest")
            let senderTerm = receivedJSON["senderCurrentTerm"].intValue
            
            if (currentTerm < senderTerm) {
                stepDown(term: senderTerm)
            }
            if (currentTerm > senderTerm) {
                let responseJSON : JSON = [
                    "type" : "appendEntriesResponse",
                    "success" : false,
                    "senderCurrentTerm" : currentTerm,
                    "sender" : getIFAddresses()[1]
                ]
                
                guard let jsonData = responseJSON.rawString()?.data(using: String.Encoding.utf8) else {
                    print("Couldn't create JSON")
                    return
                }
                
                let sender = receivedJSON["sender"].stringValue
                sendJsonUnicast(jsonToSend: jsonData, targetHost: sender)
            } else {
                guard var leaderIp = leaderIp else {
                    print("leaderIp problem")
                    return
                }
                leaderIp = receivedJSON["sender"].stringValue
                role = FOLLOWER
                updateRoleLabel()
                // resetTimer()
                let prevLogIdx = receivedJSON["prevLogIndex"].intValue
                let prevLogTrm = receivedJSON["prevLogTerm"].intValue
                print("prevLogIndex: " + String(prevLogIdx))
                print("prevLogTerm: " + String(prevLogTrm))
                var success = false
                if (prevLogIdx == 0 || prevLogIdx <= (log.count - 1)) {
                    print("Pass prevlogIdx check")
                    if (log.count > 0) {
                        // Should be 1 after first append!
                        if (log[prevLogIdx]["term"].intValue == prevLogTrm) {
                            print("Pass prevLogIdx term check")
                            success = true
                        }
                    } else if (log.count == 0) {
                        success = true // IS THIS DANGEROUS????? ***************************************
                    }
                }
                var idx = 0
                if (success) {
                    idx = prevLogIdx + 1
                    if getTerm(index: idx) != receivedJSON["senderCurrentTerm"].intValue {
                        print("Before array slice")
                        var logSliceArray = log
                        if (log.count > 0) {
                            logSliceArray = Array(log[0...idx - 1])
                        }
                        print("After array slice")
                        let msg = receivedJSON["message"].stringValue
                        let jsonToStore : JSON = [
                            "type" : "entry",
                            "term" : currentTerm,
                            "message" : msg,
                            "leaderIp" : leaderIp,
                            ]
                        logSliceArray.append(jsonToStore)
                        log = logSliceArray
                        print("Below is the log")
                        print(log)
                        updateLogTextField()
                        print("Successfully updated log")
                    }
                    let senderCommitIndex = receivedJSON["leaderCommitIndex"].intValue
                    commitIndex = min(senderCommitIndex, idx)
                }
                
                let responseJSON : JSON = [
                    "type" : "appendEntriesResponse",
                    "success" : success,
                    "senderCurrentTerm" : currentTerm,
                    "sender" : getIFAddresses()[1],
                    "matchIndex" : idx
                ]
                
                guard let jsonData = responseJSON.rawString()?.data(using: String.Encoding.utf8) else {
                    print("Couldn't create JSON")
                    return
                }
                
                sendJsonUnicast(jsonToSend: jsonData, targetHost: leaderIp)
            }
        } else if (type == "appendEntriesResponse") {
            // Handle success and failure
            // Need to check if nextIndex is still less, otherwise send another appendEntries thing
            
            let success = receivedJSON["success"].boolValue
            let peerTerm = receivedJSON["senderCurrentTerm"].intValue
            let sender = receivedJSON["sender"].stringValue
            let index = receivedJSON["matchIndex"].intValue
            if (currentTerm < peerTerm) {
                stepDown(term: peerTerm)
            } else if (role == LEADER && currentTerm == peerTerm) {
                if (success) {
                    matchIndex[sender] = index
                    nextIndex[sender] = index + 1
                    // Need more catching up
                    guard let nextIdx = nextIndex[sender] else {
                        print("Problem with nextIndex[sender]")
                        return
                    }
                    if ((log.count - 1) >= nextIdx) {
                        let prevLogIndex = nextIdx - 1
                        var prevLogTerm = 0
                        if (prevLogIndex >= 0) {
                            prevLogTerm = log[prevLogIndex]["term"].intValue
                        }
                        print(prevLogIndex)
                        print(prevLogTerm)
                        let sendMessage = log[nextIdx]["message"].stringValue
                        print("Message: " + sendMessage)
                        let jsonToSend : JSON = [
                            "type" : "appendEntriesRequest",
                            "leaderIp" : leaderIp,
                            "sender" : getIFAddresses()[1],
                            "message" : sendMessage,
                            "receiver" : sender,
                            "senderCurrentTerm" : currentTerm,
                            "prevLogIndex" : prevLogIndex,
                            "prevLogTerm" : prevLogTerm,
                            "leaderCommitIndex" : commitIndex
                        ]
                        guard let jsonData = jsonToSend.rawString()?.data(using: String.Encoding.utf8) else {
                            print("Couldn't create JSON or get leader IP")
                            return
                        }
                        sendJsonUnicast(jsonToSend: jsonData, targetHost: sender)
                        print("Sent appendEntriesRequest")
                    }
                    
                } else {
                    guard let currentNextIndex = nextIndex[sender] else {
                        print("Something wrong with nextIndex")
                        return
                    }
                    nextIndex[sender] = max(0, currentNextIndex - 1)
                    guard let nextIdx = nextIndex[sender] else {
                        print("Problem with nextIndex[sender]")
                        return
                    }
                    // Need more catching up
                    // breaks if send nil (heartbeats?)
                    if ((log.count - 1) >= nextIdx) {
                        let prevLogIndex = nextIdx - 1
                        var prevLogTerm = 0
                        if (prevLogIndex >= 0) {
                            prevLogTerm = log[prevLogIndex]["term"].intValue
                        }
                        print(prevLogIndex)
                        print(prevLogTerm)
                        let sendMessage = log[nextIdx]["message"].stringValue
                        print("Message: " + sendMessage)
                        let jsonToSend : JSON = [
                            "type" : "appendEntriesRequest",
                            "leaderIp" : leaderIp,
                            "sender" : getIFAddresses()[1],
                            "message" : sendMessage,
                            "receiver" : sender,
                            "senderCurrentTerm" : currentTerm,
                            "prevLogIndex" : prevLogIndex,
                            "prevLogTerm" : prevLogTerm,
                            "leaderCommitIndex" : commitIndex
                        ]
                        guard let jsonData = jsonToSend.rawString()?.data(using: String.Encoding.utf8) else {
                            print("Couldn't create JSON or get leader IP")
                            return
                        }
                        sendJsonUnicast(jsonToSend: jsonData, targetHost: sender)
                        print("Sent appendEntriesRequest")
                    }
                }
            }
        }
    }
    
    func getTerm(index: Int) -> Int {
        if (index < 1 || index >= log.count) {
            return 0
        } else {
            return log[index]["term"].intValue
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
        guard let socket = udpUnicastSocket else {
            print("Setup sockets")
            return
        }
        print(getIFAddresses())
        do {
            try socket.bind(toPort: 20011)
            try socket.beginReceiving()
        } catch {
            print(error)
        }
    }
    
    func sendJsonUnicast(jsonToSend: Data, targetHost: String) {
        guard let socket = udpUnicastSocket else {
            print("Socket or leaderIp could not be initialized")
            return
        }
        
        socket.send(jsonToSend, toHost: targetHost, port: 20011, withTimeout: -1, tag: 0)
    }
    
    func receiveClientMessage(message: String) {
        guard let leaderIp = leaderIp else {
            print("No leader IP")
            return
        }
        if (role == FOLLOWER || role == CANDIDATE || leaderIp != getIFAddresses()[1]) {
            // Redirect request to leader
            let jsonToSend : JSON = [
                "type" : "redirect",
                "address" : leaderIp,
                "message" : message,
                "from" : getIFAddresses()[1],
                "currentTerm" : currentTerm
            ]
            
            guard let jsonData = jsonToSend.rawString()?.data(using: String.Encoding.utf8) else {
                print("Couldn't create JSON or get leader IP")
                return
            }
            
            sendJsonUnicast(jsonToSend: jsonData, targetHost: leaderIp)
        } else if (role == LEADER) {
            // Add to log and send append entries RPC
            let jsonToStore : JSON = [
                "type" : "entry",
                "term" : currentTerm,
                "message" : message,
                "leaderIp" : leaderIp,
            ]
            log.append(jsonToStore)
            updateLogTextField()
            appendEntries()
        }
    }
    
    func appendEntries() {
        // Send appendEntry to everyone in cluster
        for server in cluster {
            if (server == getIFAddresses()[1]) {
                // Does not need to send to self
                continue
            }
            // DispatchQueue async? -> concurrently perform actions? -> delays could lead to timeout
            guard let nextIdx = self.nextIndex[server], let leaderIp = leaderIp else {
                print("Couldn't get next index or leaderIp")
                return
            }
            
            
            if ((log.count - 1) >= nextIdx) {
                let prevLogIndex = nextIdx - 1
                var prevLogTerm = 0
                if (prevLogIndex >= 0) {
                    prevLogTerm = log[prevLogIndex]["term"].intValue
                }
                print(prevLogIndex)
                print(prevLogTerm)
                let sendMessage = log[nextIdx]["message"].stringValue
                print("Message: " + sendMessage)
                 let jsonToSend : JSON = [
                    "type" : "appendEntriesRequest",
                    "leaderIp" : leaderIp,
                    "sender" : getIFAddresses()[1],
                    "message" : sendMessage,
                    "receiver" : server,
                    "senderCurrentTerm" : currentTerm,
                    "prevLogIndex" : prevLogIndex,
                    "prevLogTerm" : prevLogTerm,
                    "leaderCommitIndex" : commitIndex
                    ]
                guard let jsonData = jsonToSend.rawString()?.data(using: String.Encoding.utf8) else {
                    print("Couldn't create JSON or get leader IP")
                    return
                }
                sendJsonUnicast(jsonToSend: jsonData, targetHost: server)
                print("Sent appendEntriesRequest")
            }
        }
    }
}

