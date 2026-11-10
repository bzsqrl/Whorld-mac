// This file is part of Whorld for macOS, a port of Whorld by Chris Korda.
// Copyright 2026 Jeff Matson.
// Written with Claude (Anthropic).
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file at the repository root.
//
// Uses Syphon.framework (mac/third_party/Syphon-Framework), copyright 2010
// bangnoise (Tom Butterworth) & vade (Anton Marini), under its BSD license
// (License.txt there; also in the DMG as Syphon License.txt).

#import "WHSyphon.h"

#import <Metal/Metal.h>
#import <Syphon/Syphon.h>
#include <IOSurface/IOSurface.h>

@implementation WHSyphon {
	id<MTLDevice>	_device;
	id<MTLCommandQueue>	_queue;
	SyphonMetalServer	*_server;
	dispatch_queue_t	_publishQueue;
	NSMapTable<id, id<MTLTexture>>	*_textures;	// IOSurface -> its texture (the pools are small)
	BOOL	_stopped;	// on the publish queue
}

- (instancetype)initWithName:(NSString *)name
{
	if ((self = [super init])) {
		_device = MTLCreateSystemDefaultDevice();
		if (!_device)
			return nil;
		_queue = [_device newCommandQueue];
		_server = [[SyphonMetalServer alloc] initWithName:name device:_device options:nil];
		if (!_server)
			return nil;
		_publishQueue = dispatch_queue_create("whorld.syphon", DISPATCH_QUEUE_SERIAL);
		_textures = [NSMapTable strongToStrongObjectsMapTable];
	}
	return self;
}

- (void)dealloc
{
	[self stop];
}

- (BOOL)hasClients { return _server.hasClients; }

- (void)stop
{
	dispatch_sync(_publishQueue, ^{
		if (self->_stopped)
			return;
		self->_stopped = YES;
		[self->_server stop];
		[self->_textures removeAllObjects];
	});
}

- (void)publishSurface:(IOSurfaceRef)surface
{
	if (!surface)
		return;
	IOSurfaceIncrementUseCount(surface);	// ours until the GPU has copied it
	CFRetain(surface);
	dispatch_async(_publishQueue, ^{
		id	key = (__bridge id)surface;
		id<MTLTexture>	tex = self->_stopped ? nil : [self->_textures objectForKey:key];
		if (!tex && !self->_stopped) {
			if (self->_textures.count > 16)	// sizes changed: forget the old surfaces
				[self->_textures removeAllObjects];
			MTLTextureDescriptor	*d = [MTLTextureDescriptor
				texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
				width:IOSurfaceGetWidth(surface) height:IOSurfaceGetHeight(surface) mipmapped:NO];
			d.usage = MTLTextureUsageShaderRead;
			d.storageMode = MTLStorageModeShared;
			tex = [self->_device newTextureWithDescriptor:d iosurface:surface plane:0];
			if (tex)
				[self->_textures setObject:tex forKey:key];
		}
		id<MTLCommandBuffer>	cmd = tex ? [self->_queue commandBuffer] : nil;
		if (!cmd) {
			IOSurfaceDecrementUseCount(surface);
			CFRelease(surface);
			return;
		}
		// Whorld's surfaces are top row first, as Metal textures are: not flipped
		[self->_server publishFrameTexture:tex onCommandBuffer:cmd
			imageRegion:NSMakeRect(0, 0, tex.width, tex.height) flipped:NO];
		[cmd addCompletedHandler:^(id<MTLCommandBuffer>) {
			IOSurfaceDecrementUseCount(surface);
			CFRelease(surface);
		}];
		[cmd commit];
	});
}

@end
