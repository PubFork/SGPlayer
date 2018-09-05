//
//  SGAsyncDecoder.m
//  SGPlayer
//
//  Created by Single on 2018/1/19.
//  Copyright © 2018年 single. All rights reserved.
//

#import "SGAsyncDecoder.h"
#import "SGMacro.h"

@interface SGAsyncDecoder () <NSLocking>

@property (nonatomic, assign, readonly) SGDecoderState state;
@property (nonatomic, strong) NSLock * coreLock;
@property (nonatomic, strong) NSOperationQueue * operationQueue;
@property (nonatomic, strong) NSOperation * decodeOperation;
@property (nonatomic, strong) NSCondition * pausedCondition;
@property (atomic, assign) BOOL waitingFlush;

@end

@implementation SGAsyncDecoder

@synthesize delegate = _delegate;
@synthesize timebase = _timebase;

static SGPacket * flushPacket;

- (SGMediaType)mediaType
{
    return SGMediaTypeUnknown;
}

- (instancetype)init
{
    if (self = [super init])
    {
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            flushPacket = [[SGPacket alloc] init];
            [flushPacket lock];
        });
        _packetQueue = [[SGObjectQueue alloc] init];
        self.pausedCondition = [[NSCondition alloc] init];
        self.operationQueue = [[NSOperationQueue alloc] init];
        self.operationQueue.maxConcurrentOperationCount = 1;
        self.operationQueue.qualityOfService = NSQualityOfServiceUserInteractive;
    }
    return self;
}

- (void)dealloc
{
    
}

#pragma mark - Setter & Getter

- (SGBasicBlock)setState:(SGDecoderState)state
{
    if (_state != state)
    {
        SGDecoderState previous = _state;
        _state = state;
        if (previous == SGDecoderStatePaused)
        {
            [self.pausedCondition lock];
            [self.pausedCondition broadcast];
            [self.pausedCondition unlock];
        }
        return ^{
            [self.delegate decoderDidChangeState:self];
        };
    }
    return ^{};
}

- (BOOL)empty
{
    return self.count <= 0;
}

- (CMTime)duration
{
    return self.packetQueue.duration;
}

- (long long)size
{
    return self.packetQueue.size;
}

- (NSUInteger)count
{
    return self.packetQueue.count;
}

#pragma mark - Interface

- (BOOL)open
{
    [self lock];
    if (self.state != SGDecoderStateNone)
    {
        [self unlock];
        return NO;
    }
    SGBasicBlock callback = [self setState:SGDecoderStateDecoding];
    [self unlock];
    callback();
    [self startDecodeThread];
    return YES;
}

- (BOOL)pause
{
    [self lock];
    if (self.state != SGDecoderStateDecoding)
    {
        [self unlock];
        return NO;
    }
    SGBasicBlock callback = [self setState:SGDecoderStatePaused];
    [self unlock];
    callback();
    return YES;
}

- (BOOL)resume
{
    [self lock];
    if (self.state != SGDecoderStatePaused)
    {
        [self unlock];
        return NO;
    }
    SGBasicBlock callback = [self setState:SGDecoderStateDecoding];
    [self unlock];
    callback();
    return YES;
}

- (BOOL)close
{
    [self lock];
    if (self.state == SGDecoderStateClosed)
    {
        [self unlock];
        return NO;
    }
    SGBasicBlock callback = [self setState:SGDecoderStateClosed];
    [self unlock];
    callback();
    [self.packetQueue destroy];
    [self.operationQueue cancelAllOperations];
    [self.operationQueue waitUntilAllOperationsAreFinished];
    self.operationQueue = nil;
    self.decodeOperation = nil;
    return YES;
}

- (BOOL)putPacket:(SGPacket *)packet
{
    [self lock];
    if (self.state == SGDecoderStateClosed)
    {
        [self unlock];
        return NO;
    }
    [self unlock];
    [self.packetQueue putObjectSync:packet];
    [self.delegate decoderDidChangeCapacity:self];
    return YES;
}

- (BOOL)flush
{
    [self lock];
    if (self.state == SGDecoderStateClosed)
    {
        [self unlock];
        return NO;
    }
    [self unlock];
    [self.packetQueue flush];
    self.waitingFlush = YES;
    [self.packetQueue putObjectSync:flushPacket];
    [self.delegate decoderDidChangeCapacity:self];
    return YES;
}

#pragma mark - Decode

- (void)startDecodeThread
{
    SGWeakSelf
    self.decodeOperation = [NSBlockOperation blockOperationWithBlock:^{
        SGStrongSelf
        [self decodeThread];
    }];
    self.decodeOperation.queuePriority = NSOperationQueuePriorityVeryHigh;
    self.decodeOperation.qualityOfService = NSQualityOfServiceUserInteractive;
    self.decodeOperation.name = [NSString stringWithFormat:@"%@-Decode-Queue", self.class];
    [self.operationQueue addOperation:self.decodeOperation];
}

- (void)decodeThread
{
    while (YES)
    {
        @autoreleasepool
        {
            [self lock];
            if (self.state == SGDecoderStateNone ||
                self.state == SGDecoderStateClosed)
            {
                [self unlock];
                break;
            }
            else if (self.state == SGDecoderStatePaused)
            {
                [self.pausedCondition lock];
                [self unlock];
                [self.pausedCondition wait];
                [self.pausedCondition unlock];
                continue;
            }
            else if (self.state == SGDecoderStateDecoding)
            {
                [self unlock];
                SGPacket * packet = [self.packetQueue getObjectSync];
                if (packet == flushPacket)
                {
                    [self doFlush];
                    self.waitingFlush = NO;
                }
                else if (packet)
                {
                    if (packet.codecpar != self.codecpar)
                    {
                        [self doDestory];
                        self.codecpar = packet.codecpar;
                        self.timebase = packet.timebase;
                        [self doSetup];
                        self.decodePacketCount = 0;
                        self.decodeFrameCount = 0;
                    }
                    if (!self.waitingFlush)
                    {
                        self.decodePacketCount++;
                        NSArray <__kindof SGFrame *> * frames = [self doDecode:packet];
                        for (__kindof SGFrame * frame in frames)
                        {
                            if (!self.waitingFlush)
                            {
                                self.decodeFrameCount++;
                                [self.delegate decoder:self hasNewFrame:frame];
                            }
                            [frame unlock];
                        }
                    }
                    [self.delegate decoderDidChangeCapacity:self];
                }
                [packet unlock];
                continue;
            }
        }
    }
}

- (void)doSetup
{
    
}

- (void)doDestory
{
    
}

- (void)doFlush
{
    
}

- (NSArray <__kindof SGFrame *> *)doDecode:(SGPacket *)packet
{
    return nil;
}

#pragma mark - NSLocking

- (void)lock
{
    if (!self.coreLock)
    {
        self.coreLock = [[NSLock alloc] init];
    }
    [self.coreLock lock];
}

- (void)unlock
{
    [self.coreLock unlock];
}

@end
