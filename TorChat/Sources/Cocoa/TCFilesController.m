/*
 *  TCFilesController.m
 *
 *  Copyright 2012 Avérous Julien-Pierre
 *
 *  This file is part of TorChat.
 *
 *  TorChat is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  TorChat is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with TorChat.  If not, see <http://www.gnu.org/licenses/>.
 *
 */



#import "TCFilesController.h"



/*
** TCFilesController - Private
*/
#pragma mark - TCFilesController - Private

@interface TCFilesController ()
{
	NSMutableArray *_files;
}

- (void)_updateCount;

@end



/*
** TCFilesController
*/
#pragma mark - TCFilesController

@implementation TCFilesController


/*
** TCFilesController - Instance
*/
#pragma mark - TCFilesController - Instance

+ (TCFilesController *)sharedController
{
	static dispatch_once_t		onceToken;
	static TCFilesController	*shr;
	
	dispatch_once(&onceToken, ^{
		shr = [[TCFilesController alloc] init];
	});

	return shr;
}

- (id)init
{
	self = [super init];
	
    if (self)
	{
		// Alloc files array
		_files =  [[NSMutableArray alloc] init];
		
		// Register notification
		NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
		
		[center addObserver:self selector:@selector(fileReveal:) name:TCFileCellRevealNotify object:nil];
		[center addObserver:self selector:@selector(fileOpen:) name:TCFileCellOpenNotify object:nil];

		// Load the nib
		[[NSBundle mainBundle] loadNibNamed:@"FilesWindow" owner:self topLevelObjects:nil];
    }
    
    return self;
}

- (void)awakeFromNib
{
	[_mainWindow center];
	[_mainWindow setFrameAutosaveName:@"FilesWindow"];

	[self _updateCount];
}



/*
** TCFilesController - Interface
*/
#pragma mark - TCFilesController - Interface

- (IBAction)doClear:(id)sender
{
	NSNotificationCenter	*center = [NSNotificationCenter defaultCenter];
	NSMutableIndexSet		*indSet = [NSMutableIndexSet indexSet];
	NSUInteger				i, cnt = [_files count];
	
	for (i = 0; i < cnt; i++)
	{
		NSDictionary	*file = [_files objectAtIndex:i];
		tcfile_status	status = (tcfile_status)[[file objectForKey:TCFileStatusKey] intValue];

		if (status != tcfile_status_running)
		{
			NSString		*uuid = [file objectForKey:TCFileUUIDKey];
			NSNumber		*way = [file objectForKey:TCFileWayKey];
			NSDictionary	*info = [[NSDictionary alloc] initWithObjectsAndKeys:uuid, @"uuid", way, @"way", nil];

			[center postNotificationName:TCFileRemovingNotify object:self userInfo:info];
			
			[indSet addIndex:i];
		}
	}
	
	[_files removeObjectsAtIndexes:indSet];
	
	[_filesView reloadData];
	
	[self _updateCount];
}

- (IBAction)showWindow:(id)sender
{
	[_mainWindow makeKeyAndOrderFront:sender];
}



/*
** TCFilesController - Actions
*/
#pragma mark - TCFilesController - Action

- (void)startFileTransfert:(NSString *)uuid withFilePath:(NSString *)filePath buddyAddress:(NSString *)address buddyName:(NSString *)name transfertWay:(tcfile_way)way fileSize:(uint64_t)size
{
	if (!uuid || !filePath || !name || !address)
		return;
	
	// Build file description
	NSMutableDictionary *item = [[NSMutableDictionary alloc] initWithCapacity:7];
	NSImage				*icon = [[NSWorkspace sharedWorkspace] iconForFileType:[filePath pathExtension]];
	
	[icon setSize:NSMakeSize(50, 50)];
	[icon lockFocus];
	{
		NSImage *badge = nil;
		
		if (way == tcfile_upload)
			badge = [NSImage imageNamed:@"file_up"];
		else if (way == tcfile_download)
			badge = [NSImage imageNamed:@"file_down"];
		
		if (badge)
			[badge drawAtPoint:NSMakePoint(50 - 16, 0) fromRect:NSMakeRect(0, 0, 16, 16) operation:NSCompositeSourceOver fraction:1.0];
	}
	[icon unlockFocus];
	
	[item setObject:uuid forKey:TCFileUUIDKey];
	[item setObject:filePath forKey:TCFileFilePathKey];
	[item setObject:address forKey:TCFileBuddyAddressKey];
	[item setObject:name forKey:TCFileBuddyNameKey];
	[item setObject:[NSNumber numberWithInt:way] forKey:TCFileWayKey];
	[item setObject:[NSNumber numberWithInt:tcfile_status_running] forKey:TCFileStatusKey];
	[item setObject:[NSNumber numberWithFloat:0.0] forKey:TCFilePercentKey];
	[item setObject:icon forKey:TCFileIconKey];
	[item setObject:[NSNumber numberWithUnsignedLongLong:size] forKey:TCFileSizeKey];
	[item setObject:[NSNumber numberWithUnsignedLongLong:0] forKey:TCFileCompletedKey];
	
	if (way == tcfile_upload)
		[item setObject:NSLocalizedString(@"file_uploading", @"") forKey:TCFileStatusTextKey];
	else if (way == tcfile_download)
		[item setObject:NSLocalizedString(@"file_downloading", @"") forKey:TCFileStatusTextKey];
	
	// Make internal & interface changes in main thread
	dispatch_async(dispatch_get_main_queue(), ^{
		
		// Add the file
		[_files addObject:item];
				
		// Reload the view
		[_filesView reloadData];
		
		// Reaload count
		[self _updateCount];
		
		// Show the window
		[_mainWindow makeKeyAndOrderFront:self];
	});
}

- (void)setStatus:(tcfile_status)status andTextStatus:(NSString *)txtStatus forFileTransfert:(NSString *)uuid withWay:(tcfile_way)way
{
	if (!txtStatus)
		return;
	
	dispatch_async(dispatch_get_main_queue(), ^{
		
		for (NSMutableDictionary *file in _files)
		{
			NSString	*auuid = [file objectForKey:TCFileUUIDKey];
			tcfile_way	away = (tcfile_way)[[file objectForKey:TCFileWayKey] intValue];
			
			if (away == way && [auuid isEqualToString:uuid])
			{
				[file setObject:[NSNumber numberWithInt:status] forKey:TCFileStatusKey];
				[file setObject:txtStatus forKey:TCFileStatusTextKey];
				
				[_filesView reloadData];
				[self _updateCount];
				break;
			}
		}
		
	});
}

- (void)setCompleted:(uint64_t)size forFileTransfert:(NSString *)uuid withWay:(tcfile_way)way
{
	dispatch_async(dispatch_get_main_queue(), ^{
		
		for (NSMutableDictionary *file in _files)
		{
			NSString	*auuid = [file objectForKey:TCFileUUIDKey];
			tcfile_way	away = (tcfile_way)[[file objectForKey:TCFileWayKey] intValue];
			
			if (away == way && [auuid isEqualToString:uuid])
			{
				[file setObject:[NSNumber numberWithUnsignedLongLong:size] forKey:TCFileCompletedKey];
				
				[_filesView reloadData];
				[self _updateCount];
				break;
			}
		}
	});
}



/*
** TCFilesController - Table View
*/
#pragma mark - TCFilesController - Table View

- (NSInteger)numberOfRowsInTableView:(NSTableView *)aTableView
{	
	return (NSInteger)[_files count];
}

- (id)tableView:(NSTableView *)aTableView objectValueForTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex
{
	if (rowIndex < 0 || rowIndex >= [_files count])
		return nil;
	
	NSMutableDictionary *file = [_files objectAtIndex:(NSUInteger)rowIndex];
	
	return file;
}

- (BOOL)doDeleteKeyInTableView:(NSTableView *)aTableView
{
	NSIndexSet				*set = [_filesView selectedRowIndexes];
	NSMutableIndexSet		*final = [NSMutableIndexSet indexSet];
	NSNotificationCenter	*center = [NSNotificationCenter defaultCenter];
    NSUInteger				currentIndex = [set firstIndex];
	
    while (currentIndex != NSNotFound)
	{
		NSDictionary	*file = [_files objectAtIndex:currentIndex];
		tcfile_status	status = (tcfile_status)[[file objectForKey:TCFileStatusKey] intValue];

		if (status != tcfile_status_running)
		{
			NSString		*uuid = [file objectForKey:TCFileUUIDKey];
			NSNumber		*way = [file objectForKey:TCFileWayKey];
			NSDictionary	*info = [[NSDictionary alloc] initWithObjectsAndKeys:uuid, @"uuid", way, @"way", nil];
			
			// Inform of the remove
			[center postNotificationName:TCFileRemovingNotify object:self userInfo:info];
					
			[final addIndex:currentIndex];
		}

        currentIndex = [set indexGreaterThanIndex:currentIndex];
    }
	
	if ([final count] == 0)
		return NO;
	
	// Remove items from array
	[_files removeObjectsAtIndexes:final];
	
	// Reload
	[_filesView reloadData];
	[self _updateCount];
	
	return YES;
}



/*
** TCFilesController - Cell Notification
*/
#pragma mark - TCFilesController - Cell Notification

- (void)fileReveal:(NSNotification *)notice
{
	NSDictionary	*info = [notice userInfo];
	NSString		*uuid = [info objectForKey:@"uuid"];
	tcfile_way		way = (tcfile_way)[[info objectForKey:@"way"] intValue];
	
	for (NSMutableDictionary *file in _files)
	{
		NSString	*auuid = [file objectForKey:TCFileUUIDKey];
		tcfile_way	away = (tcfile_way)[[file objectForKey:TCFileWayKey] intValue];
		
		if (away == way && [auuid isEqualToString:uuid])
		{
			NSString *path = [file objectForKey:TCFileFilePathKey];
			
			[[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:nil];			
			break;
		}
	}
}

- (void)fileOpen:(NSNotification *)notice
{
	NSDictionary	*info = [notice userInfo];
	NSString		*uuid = [info objectForKey:@"uuid"];
	tcfile_way		way = (tcfile_way)[[info objectForKey:@"way"] intValue];
		
	for (NSMutableDictionary *file in _files)
	{
		NSString	*auuid = [file objectForKey:TCFileUUIDKey];
		tcfile_way	away = (tcfile_way)[[file objectForKey:TCFileWayKey] intValue];
		
		if (away == way && [auuid isEqualToString:uuid])
		{
			NSString *path = [file objectForKey:TCFileFilePathKey];
			
			[[NSWorkspace sharedWorkspace] openFile:path];
			break;
		}
	}
}



/*
** TCFilesController - Private
*/
#pragma mark - TCFilesController - Private

- (void)_updateCount
{
	// > in main queue <
	
	unsigned count_up = 0;
	unsigned count_down = 0;
	unsigned count_run = 0;
	unsigned count_unrun = 0;
	
	for (NSDictionary *file in _files)
	{
		tcfile_status	status = (tcfile_status)[[file objectForKey:TCFileStatusKey] intValue];
		tcfile_way		way = (tcfile_way)[[file objectForKey:TCFileWayKey] intValue];
		
		if (status == tcfile_status_running)
			count_run++;
		else
			count_unrun++;
		
		if (way == tcfile_upload)
			count_up++;
		else if (way == tcfile_download)
			count_down++;
	}
	
	// Activate items
	[_clearButton setEnabled:(count_unrun > 0)];
	[_countField setHidden:([_files count] == 0)];

	// Build up string
	NSString *txt_up = nil;
	if (count_up > 1)
		txt_up = [NSString stringWithFormat:NSLocalizedString(@"file_uploads", @""), count_up];
	else if (count_up > 0)
		txt_up = NSLocalizedString(@"one_upload", @"");
	
	// Build down string
	NSString *txt_down = nil;
	if (count_down > 1)
		txt_down = [NSString stringWithFormat:NSLocalizedString(@"file_downloads", @""), count_up];
	else if (count_down > 0)
		txt_down = NSLocalizedString(@"one_download", @"");

	// Show the final string
	if (txt_up && txt_down)
		[_countField setStringValue:[NSString stringWithFormat:@"%@ — %@", txt_down, txt_up]];
	else
	{
		if (txt_up)
			[_countField setStringValue:txt_up];
		else if (txt_down)
			[_countField setStringValue:txt_down];
	}
}

@end
