/*
    File: ClientController.m
Abstract: 
This class implements the controller object for the client application. It is 
responsible for looking up the server application, and responding to frame
rendering requests from the server.

 Version: 1.2

Disclaimer: IMPORTANT:  This Apple software is supplied to you by Apple
Inc. ("Apple") in consideration of your agreement to the following
terms, and your use, installation, modification or redistribution of
this Apple software constitutes acceptance of these terms.  If you do
not agree with these terms, please do not use, install, modify or
redistribute this Apple software.

In consideration of your agreement to abide by the following terms, and
subject to these terms, Apple grants you a personal, non-exclusive
license, under Apple's copyrights in this original Apple software (the
"Apple Software"), to use, reproduce, modify and redistribute the Apple
Software, with or without modifications, in source and/or binary forms;
provided that if you redistribute the Apple Software in its entirety and
without modifications, you must retain this notice and the following
text and disclaimers in all such redistributions of the Apple Software.
Neither the name, trademarks, service marks or logos of Apple Inc. may
be used to endorse or promote products derived from the Apple Software
without specific prior written permission from Apple.  Except as
expressly stated in this notice, no other rights or licenses, express or
implied, are granted by Apple herein, including but not limited to any
patent rights that may be infringed by your derivative works or by other
works in which the Apple Software may be incorporated.

The Apple Software is provided by Apple on an "AS IS" basis.  APPLE
MAKES NO WARRANTIES, EXPRESS OR IMPLIED, INCLUDING WITHOUT LIMITATION
THE IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY AND FITNESS
FOR A PARTICULAR PURPOSE, REGARDING THE APPLE SOFTWARE OR ITS USE AND
OPERATION ALONE OR IN COMBINATION WITH YOUR PRODUCTS.

IN NO EVENT SHALL APPLE BE LIABLE FOR ANY SPECIAL, INDIRECT, INCIDENTAL
OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
INTERRUPTION) ARISING IN ANY WAY OUT OF THE USE, REPRODUCTION,
MODIFICATION AND/OR DISTRIBUTION OF THE APPLE SOFTWARE, HOWEVER CAUSED
AND WHETHER UNDER THEORY OF CONTRACT, TORT (INCLUDING NEGLIGENCE),
STRICT LIABILITY OR OTHERWISE, EVEN IF APPLE HAS BEEN ADVISED OF THE
POSSIBILITY OF SUCH DAMAGE.

Copyright (C) 2014 Apple Inc. All Rights Reserved.

*/

#import "ClientController.h"
#import "MultiGPUMig.h"
#import "MultiGPUMigServer.h"
#import "ClientOpenGLView.h"

@interface ClientController()
{
	IBOutlet NSWindow *_window;
	IBOutlet ClientOpenGLView *_view;
	IBOutlet NSPopUpButton *_rendererPopup;
	
    NSTimer *_timer;
	NSMachPort *serverPort;
	NSMachPort *localPort;
	
	uint32_t serverPortName;
	uint32_t localPortName;
    
	int32_t clientIndex;
	uint32_t nextFrameIndex;
	
	IOSurfaceRef _ioSurfaceBuffers[NUM_IOSURFACE_BUFFERS];
	GLuint _textureNames[NUM_IOSURFACE_BUFFERS];
    uint32_t _lastSeed[NUM_IOSURFACE_BUFFERS];
    
	uint32_t rendererIndex;
}
@end

@implementation ClientController

- (void)applicationWillFinishLaunching:(NSNotification *)note
{
    [[NSNotificationCenter defaultCenter] addObserver:self 
	    selector:@selector(portDied:) name:NSPortDidBecomeInvalidNotification object:nil];
	
	[_rendererPopup removeAllItems];
	[_rendererPopup addItemsWithTitles:[_view rendererNames]];
    
    [_view setRendererIndex:0];
    [_rendererPopup selectItemAtIndex:0];
}

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    // Fire up animation timer.
    _timer = [[NSTimer timerWithTimeInterval:1.0f/60.0f target:self selector:@selector(animate:) userInfo:nil repeats:YES] retain];
    [[NSRunLoop currentRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}


- (void)animate:(NSTimer *)timer
{
    [(ClientController *)[NSApp delegate] displayFrame:0 surfaceid:0x9];
}

- (void)portDied:(NSNotification *)notification
{
	NSPort *port = [notification object];
	if(port == serverPort)
	{
		[NSApp terminate:self];
	}
}

- (void)handleMachMessage:(void *)msg
{
	union __ReplyUnion___MGCMGSServer_subsystem reply;
	
	mach_msg_header_t *reply_header = (void *)&reply;
	kern_return_t kr;
	
	if(MGSServer_server(msg, reply_header) && reply_header->msgh_remote_port != MACH_PORT_NULL)
	{
		kr = mach_msg(reply_header, MACH_SEND_MSG, reply_header->msgh_size, 0, MACH_PORT_NULL, 
			     0, MACH_PORT_NULL);
        if(kr != 0)
			[NSApp terminate:nil];
	}
}

- (kern_return_t)displayFrame:(int32_t)frameIndex surfaceid:(uint32_t)iosurface_id
{
	
    nextFrameIndex = frameIndex;

	if(!_ioSurfaceBuffers[frameIndex])
	{
        fprintf(stderr, "IOSurface: 0x%x\n", iosurface_id);
		_ioSurfaceBuffers[frameIndex] = IOSurfaceLookup(iosurface_id);
        IOSurfaceRef surface = _ioSurfaceBuffers[frameIndex];
        IOSurfaceIncrementUseCount(surface);
        fprintf(stderr, "Use: %u, Count: %u, Size: %u x %u, Format: %u\n",
                IOSurfaceIsInUse(surface),
                IOSurfaceGetUseCount(surface),
                IOSurfaceGetWidth(surface), IOSurfaceGetHeight(surface),
                IOSurfaceGetPixelFormat(surface));

        CGFloat width = IOSurfaceGetWidth(surface);
        CGFloat height = IOSurfaceGetHeight(surface);
//        NSSize textureSize = NSMakeSize(width, height);
//        [_view setBoundsSize:[_view convertSizeFromBacking:textureSize]];

        NSSize frameSize = [_view frame].size;
        NSSize boundsSize = [_view bounds].size;
        NSSize backingSize = [_view convertSizeToBacking:[_view bounds].size];
        fprintf(stderr, "Frame: %u x %u, Bounds: %u x %u, Backing: %u x %u\n",
                (uint)frameSize.width, (uint)frameSize.height,
                (uint)boundsSize.width, (uint)boundsSize.height,
                (uint)backingSize.width, (uint)backingSize.height);

        const GLubyte* strVersion = glGetString(GL_VERSION);
        fprintf(stderr, "%s\n", strVersion);
	}

    IOSurfaceRef surface = _ioSurfaceBuffers[frameIndex];
    uint32_t seed = IOSurfaceGetSeed(surface);
    if (_lastSeed[frameIndex] == seed) {
        // Surface is unchanged, nothing to do
        return 0;
    }
    _lastSeed[frameIndex] = seed;

	if(!_textureNames[frameIndex])
		_textureNames[frameIndex] = [_view setupIOSurfaceTexture:surface];
	
	[_view setNeedsDisplay:YES];
	[_view display];
	
	return 0;
}

// For the clients, this is a no-op.
kern_return_t _MGSCheckinClient(mach_port_t server_port, mach_port_t client_port,
			       int32_t *client_index)
{
	return 0;
}

kern_return_t _MGSDisplayFrame(mach_port_t server_port, int32_t frame_index, uint32_t iosurface_id)
{
	return [(ClientController *)[NSApp delegate] displayFrame:frame_index surfaceid:iosurface_id];
}

- (GLuint)currentTextureName
{
	return _textureNames[nextFrameIndex];
}

- (IBAction)setRenderer:(id)sender
{
	[_view setRendererIndex:(rendererIndex = [sender indexOfSelectedItem])];
}

@end
