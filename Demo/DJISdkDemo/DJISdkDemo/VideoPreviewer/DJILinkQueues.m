//
//  DJILinkQueues.m
//  DJI
//
//  Copyright (c) 2013年. All rights reserved.
//

#import "DJILinkQueues.h"
#import <sys/time.h>

/**
 *  队列的节点
 */
typedef struct{
    uint8_t *ptr;
    int size;
}DJILinkNode;

@interface DJILinkQueues()
{
    //node
    DJILinkNode *_node;
    //指针总数
    int _size;
    //指针数量
    int _count;
    //指针头
    int _head;
    int _tail;
    
    //队列锁
    pthread_mutex_t _mutex;
    //互斥锁
    pthread_cond_t _cond;
    
    // A reserve of all bytes since the last AUD start
    NSMutableData* _reserveVideoData;
}
@end

@implementation DJILinkQueues

- (DJILinkQueues *)initWithSize:(int)size{
    self = [super init];
    pthread_mutex_init(&_mutex, NULL);
    pthread_cond_init(&_cond, NULL);
    _head = 0;
    _tail = 0;
    _count = 0;
    _size = 0;
    _node = NULL;
    if(size<=0)return self;
    _size = size;
    _node = (DJILinkNode *)malloc(size*sizeof(DJILinkNode));
    
    _reserveVideoData = [[NSMutableData alloc] init];
    
    return self;
}

//清空队列，在此期间队列加锁
- (void)clear{
    pthread_mutex_lock(&_mutex);
    int idx = 0;
    for(int i = 0;i<_count;i++){
        if(i+_head>=_size){
            idx = i+_head-_size;
        }
        else {
            idx = i+_head;
        }
        if(_node[idx].ptr!=NULL){
            free(_node[idx].ptr);
            _node[idx].ptr = NULL;
        }
        _node[idx].size = 0;
    }
    _head = 0;
    _tail = 0;
    _count = 0;

    // Copy the reserve of video data into the queue
    uint8_t* pBuffer = (uint8_t*)malloc(_reserveVideoData.length);
    memcpy(pBuffer, [_reserveVideoData bytes], _reserveVideoData.length);
    [self push:pBuffer length:(int)_reserveVideoData.length mutex:&_mutex cond:&_cond];
    
    pthread_mutex_unlock(&_mutex);
}

//进队列(返回值为No时队列满,长度为0或buf为NULL也返回NO)
- (bool)push:(uint8_t *)buf length:(int)len{
    pthread_mutex_lock(&_mutex);

    // Start hunting the length of a start sequence from the end of the reserve
    int startingIndex = (int)_reserveVideoData.length - 5;
    if (startingIndex < 0) {
        startingIndex = 0;
    }
    
    // Enqueue the data
    bool retVal = [self push:buf length:len mutex:&_mutex cond:&_cond];
    
    // Update the reserve
    [_reserveVideoData appendBytes:buf length:len];
    int start = -1;
    // If the reserve has a start sequence and is a type 9 NAL (AUD), find the last start sequence and trim the front of the reserve.
    // If not, add the whole thing to the reserve because it's in the middle of an access unit.
    for (int i = startingIndex; i < _reserveVideoData.length-4; i++) {
        if (((uint8_t*)_reserveVideoData.bytes)[i] == 0x00 &&
            ((uint8_t*)_reserveVideoData.bytes)[i+1] == 0x00 &&
            ((uint8_t*)_reserveVideoData.bytes)[i+2] == 0x00 &&
            ((uint8_t*)_reserveVideoData.bytes)[i+3] == 0x01 &&
            (((uint8_t*)_reserveVideoData.bytes)[i+4] & 0x1F) == 0x9) {
            start = i; // This is the latest start sequence found
        }
    }
    // If there is a start sequence, throw away the
    if (start != -1) {
        [_reserveVideoData replaceBytesInRange:NSMakeRange(0, start-1) withBytes:NULL length:0];
    }

    pthread_cond_signal(&_cond);
    pthread_mutex_unlock(&_mutex);
    return retVal;
}

// Helper method that can be called from within a locked context or outside of one, ensuring atomic handoff
-(bool)push:(uint8_t *)buf length:(int)len mutex:(pthread_mutex_t *)mutex cond:(pthread_cond_t *)cond {
    if (!mutex) {
        pthread_mutex_lock(mutex);
    }
    
    if(len==0 || buf==NULL || [self isFull]){
        if (!mutex) {
            pthread_mutex_unlock(mutex);
        }
        return NO;
    }
    
    _node[_tail].ptr = buf;
    _node[_tail].size = len;
    _tail++;
    if(_tail>=_size)_tail = 0;
    _count++;

    if (!mutex) {
        pthread_cond_signal(cond);
        pthread_mutex_unlock(mutex);
    }
    return YES;
}

//出队列(返回值为NULL时队列为空)
- (uint8_t *)pull:(int *)len{
    pthread_mutex_lock(&_mutex);
    if(_count == 0)
    {
        struct timeval tv;
        gettimeofday(&tv, NULL);
        
        struct timespec ts;
        ts.tv_sec = tv.tv_sec + 2;
        ts.tv_nsec = tv.tv_usec;
        pthread_cond_timedwait(&_cond, &_mutex, &ts);
        if(_count == 0)
        {
            *len = 0;
            pthread_mutex_unlock(&_mutex);
            return NULL;
        }
    }
    uint8_t *tmp = NULL;
    tmp = _node[_head].ptr;
    *len = _node[_head].size;
    _head++;
    if(_head>=_size)_head = 0;
    _count--;
    pthread_mutex_unlock(&_mutex);
    return tmp;
}

- (int)count{
    return _count;
}

- (int)size{
    return _size;
}

//是否已满
- (bool)isFull{
    if(_count==_size){
        return YES;
    }
    else{
        return NO;
    }
}
@end
