//
//  PlaylistLoader.m
//  Cog
//
//  Created by Vincent Spader on 3/05/07.
//  Copyright 2007 Vincent Spader All rights reserved.
//

#include <objc/runtime.h>

#import "PlaylistLoader.h"
#import "PlaylistController.h"
#import "PlaylistEntry.h"
#import "FilePlaylistEntry.h"
#import "AppController.h"

#import "NSFileHandle+CreateFile.h"

#import "CogAudio/AudioPlayer.h"
#import "CogAudio/AudioContainer.h"
#import "CogAudio/AudioPropertiesReader.h"
#import "CogAudio/AudioMetadataReader.h"

#import "XMlContainer.h"

#import "NSData+MD5.h"

#import "Logging.h"

@implementation PlaylistLoader

- (id)init
{
	self = [super init];
	if (self)
	{
		[self initDefaults];
		
		queue = [[NSOperationQueue alloc] init];
		[queue setMaxConcurrentOperationCount:1];
	}
	
	return self; 
}

- (void)initDefaults
{
	NSDictionary *defaultsDictionary = [NSDictionary dictionaryWithObjectsAndKeys:
										[NSNumber numberWithBool:YES], @"readCueSheetsInFolders",
										nil];
	
	[[NSUserDefaults standardUserDefaults] registerDefaults:defaultsDictionary];
}

- (BOOL)save:(NSString *)filename
{
	NSString *ext = [filename pathExtension];
	if ([ext isEqualToString:@"pls"])
	{
		return [self save:filename asType:kPlaylistPls];
	}
	else
	{
		return [self save:filename asType:kPlaylistM3u];
	}
}	

- (BOOL)save:(NSString *)filename asType:(PlaylistType)type
{
	if (type == kPlaylistM3u)
	{
		return [self saveM3u:filename];
	}
	else if (type == kPlaylistPls)
	{
		return [self savePls:filename];
	}
    else if (type == kPlaylistXml)
    {
        return [self saveXml:filename];
    }

	return NO;
}

- (NSString *)relativePathFrom:(NSString *)filename toURL:(NSURL *)entryURL
{
	NSString *basePath = [[[filename stringByStandardizingPath] stringByDeletingLastPathComponent] stringByAppendingString:@"/"];

	if ([entryURL isFileURL]) {
		//We want relative paths.
		NSMutableString *entryPath = [[[entryURL path] stringByStandardizingPath] mutableCopy];

		[entryPath replaceOccurrencesOfString:basePath withString:@"" options:(NSAnchoredSearch | NSLiteralSearch | NSCaseInsensitiveSearch) range:NSMakeRange(0, [entryPath length])];
		if ([entryURL fragment])
		{
			[entryPath appendString:@"#"];
			[entryPath appendString:[entryURL fragment]];
		}

		return entryPath;		
	}
	else {
		//Write [entryURL absoluteString] to file
		return [entryURL absoluteString];
	}
}

- (BOOL)saveM3u:(NSString *)filename
{
	NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:filename createFile:YES];
	if (!fileHandle) {
		ALog(@"Error saving m3u!");
		return NO;
	}
	[fileHandle truncateFileAtOffset:0];
	
	for (PlaylistEntry *pe in [playlistController arrangedObjects])
	{
		NSString *path = [self relativePathFrom:filename toURL:[pe URL]];
		[fileHandle writeData:[[path stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
	}

	[fileHandle closeFile];

	return YES;
}

- (BOOL)savePls:(NSString *)filename
{
	NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:filename createFile:YES];
	if (!fileHandle) {
		return NO;
	}
	[fileHandle truncateFileAtOffset:0];

	[fileHandle writeData:[[NSString stringWithFormat:@"[playlist]\nnumberOfEntries=%lu\n\n",(unsigned long)[[playlistController content] count]] dataUsingEncoding:NSUTF8StringEncoding]];

	int i = 1;
	for (PlaylistEntry *pe in [playlistController arrangedObjects])
	{
		NSString *path = [self relativePathFrom:filename toURL:[pe URL]];
		NSString *entry = [NSString stringWithFormat:@"File%i=%@\n",i,path];

		[fileHandle writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
		i++;
	}

	[fileHandle writeData:[@"\nVERSION=2" dataUsingEncoding:NSUTF8StringEncoding]];
	[fileHandle closeFile];

	return YES;
}

NSMutableDictionary * dictionaryWithPropertiesOfObject(id obj, NSArray * filterList)
{
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];

    Class class = [obj class];
    
    do {
        unsigned count;
        objc_property_t *properties = class_copyPropertyList(class, &count);
        
        for (int i = 0; i < count; i++) {
            NSString *key = [NSString stringWithUTF8String:property_getName(properties[i])];
            if ([filterList containsObject:key]) continue;
            
            Class classObject = NSClassFromString([key capitalizedString]);
            if (classObject) {
                id subObj = dictionaryWithPropertiesOfObject([obj valueForKey:key], filterList);
                [dict setObject:subObj forKey:key];
            }
            else
            {
                id value = [obj valueForKey:key];
                if(value) [dict setObject:value forKey:key];
            }
        }
        
        free(properties);
        
        if (count) break;
        
        class = [class superclass];
    } while (class);
    
    return dict;
}

- (BOOL)saveXml:(NSString *)filename
{
	NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:filename createFile:YES];
	if (!fileHandle) {
		return NO;
	}
	[fileHandle truncateFileAtOffset:0];
    
    NSArray * filterList = [NSArray arrayWithObjects:@"display", @"length", @"path", @"filename", @"status", @"statusMessage", @"spam", @"lengthText", @"positionText", @"stopAfter", @"shuffleIndex", @"index", @"current", @"queued", @"currentPosition", @"queuePosition", @"error", @"removed", @"URL", @"albumArt", nil];
    
    NSMutableDictionary * albumArtSet = [[NSMutableDictionary alloc] init];
    
    NSMutableArray * topLevel = [[NSMutableArray alloc] init];
    
	for (PlaylistEntry *pe in [playlistController arrangedObjects])
	{
        BOOL error = [pe error];
        
        NSMutableDictionary * dict = dictionaryWithPropertiesOfObject(pe, filterList);

		NSString *path = [self relativePathFrom:filename toURL:[pe URL]];
        
        [dict setObject:path forKey:@"URL"];
        NSData * albumArt = [dict objectForKey:@"albumArtInternal"];
        if (albumArt)
        {
            [dict removeObjectForKey:@"albumArtInternal"];
            NSString * hash = [albumArt MD5];
            if (![albumArtSet objectForKey:hash])
                [albumArtSet setObject:albumArt forKey:hash];
            [dict setObject:hash forKey:@"albumArt"];
        }
        
        if (error)
            [dict removeObjectForKey:@"metadataLoaded"];
        
        [topLevel addObject:dict];
	}
    
    NSMutableArray * queueList = [[NSMutableArray alloc] init];
    
    for (PlaylistEntry *pe in [playlistController queueList])
    {
        [queueList addObject:[NSNumber numberWithInt:pe.index]];
    }
    
    NSDictionary * dictionary = [NSDictionary dictionaryWithObjectsAndKeys:albumArtSet, @"albumArt", queueList, @"queue", topLevel, @"items", nil];
    
    NSData * data = [NSPropertyListSerialization dataWithPropertyList:dictionary format:NSPropertyListXMLFormat_v1_0 options:0 error:0];

    [fileHandle writeData:data];
    
    [fileHandle closeFile];

	return YES;
}

- (NSArray *)fileURLsAtPath:(NSString *)path
{
	NSFileManager *manager = [NSFileManager defaultManager];
	
	NSMutableArray *urls = [NSMutableArray array];
		
	NSArray *subpaths = [manager subpathsAtPath:path];

	for (NSString *subpath in subpaths)
	{
		NSString *absoluteSubpath = [NSString pathWithComponents:[NSArray arrayWithObjects:path,subpath,nil]];
		
		BOOL isDir;
		if ( [manager fileExistsAtPath:absoluteSubpath isDirectory:&isDir] && isDir == NO)
		{
			if ([[absoluteSubpath pathExtension] caseInsensitiveCompare:@"cue"] != NSOrderedSame ||
				[[NSUserDefaults standardUserDefaults] boolForKey:@"readCueSheetsInFolders"])
			{
				[urls addObject:[NSURL fileURLWithPath:absoluteSubpath]];
			}
		}
	}
	
	return urls;
}

- (NSArray*)insertURLs:(NSArray *)urls atIndex:(int)index sort:(BOOL)sort
{
	NSMutableSet *uniqueURLs = [NSMutableSet set];
	
	NSMutableArray *expandedURLs = [NSMutableArray array];
	NSMutableArray *containedURLs = [NSMutableArray array];
	NSMutableArray *fileURLs = [NSMutableArray array];
	NSMutableArray *validURLs = [NSMutableArray array];
    NSDictionary *xmlData = nil;
	
	if (!urls)
		return [NSArray array];
	
	if (index < 0)
		index = 0;

	NSURL *url;
	for (url in urls)
	{
		if ([url isFileURL]) {
			BOOL isDir;
			if ([[NSFileManager defaultManager] fileExistsAtPath:[url path] isDirectory:&isDir])
			{
				if (isDir == YES)
				{
					//Get subpaths
					[expandedURLs addObjectsFromArray:[self fileURLsAtPath:[url path]]];
				}
				else
				{
					[expandedURLs addObject:url];
				}
			}
		}
		else
		{
			//Non-file URL..
			[expandedURLs addObject:url];
		}
	}
	
	DLog(@"Expanded urls: %@", expandedURLs);

	NSArray *sortedURLs;
	if (sort == YES)
	{
		sortedURLs = [expandedURLs sortedArrayUsingSelector:@selector(finderCompare:)];
//		sortedURLs = [expandedURLs sortedArrayUsingSelector:@selector(compareTrackNumbers:)];
	}
	else
	{
		sortedURLs = expandedURLs;
	}

	for (url in sortedURLs)
	{
		//Container vs non-container url
		if ([[self acceptableContainerTypes] containsObject:[[url pathExtension] lowercaseString]]) {
			[containedURLs addObjectsFromArray:[AudioContainer urlsForContainerURL:url]];

			//Make sure the container isn't added twice.
			[uniqueURLs addObject:url];
		}
        else if ([[[url pathExtension] lowercaseString] isEqualToString:@"xml"])
        {
            xmlData = [XmlContainer entriesForContainerURL:url];
        }
		else
		{
			[fileURLs addObject:url];
		}
	}

	DLog(@"File urls: %@", fileURLs);

	DLog(@"Contained urls: %@", containedURLs);

	for (url in fileURLs)
	{
		if (![[AudioPlayer schemes] containsObject:[url scheme]])
			continue;
        
        NSString *ext = [[url pathExtension] lowercaseString];

		//Need a better way to determine acceptable file types than basing it on extensions.
		if ([url isFileURL] && ![[AudioPlayer fileTypes] containsObject:ext])
			continue;
		
		if (![uniqueURLs containsObject:url])
		{
			[validURLs addObject:url];
			
			[uniqueURLs addObject:url];
		}
	}
	
	DLog(@"Valid urls: %@", validURLs);

	for (url in containedURLs)
	{
		if (![[AudioPlayer schemes] containsObject:[url scheme]])
			continue;

		//Need a better way to determine acceptable file types than basing it on extensions.
		if ([url isFileURL] && ![[AudioPlayer fileTypes] containsObject:[[url pathExtension] lowercaseString]])
			continue;

		[validURLs addObject:url];
	}
	
	//Create actual entries
    int count = [validURLs count];
    if (xmlData) count += [[xmlData objectForKey:@"entries"] count];
    
	int i = 0;
	NSMutableArray *entries = [NSMutableArray arrayWithCapacity:count];
	for (NSURL *url in validURLs)
	{
		PlaylistEntry *pe;
		if ([url isFileURL]) 
			pe = [[FilePlaylistEntry alloc] init];
		else
			pe = [[PlaylistEntry alloc] init];

		pe.URL = url;
		pe.index = index+i;
		pe.title = [[url path] lastPathComponent];
		pe.queuePosition = -1;
		[entries addObject:pe];

        ++i;
	}

    int j = index + i;
    
    if (xmlData)
    {
        for (NSDictionary *entry in [xmlData objectForKey:@"entries"])
        {
            PlaylistEntry *pe;
            if ([[entry objectForKey:@"URL"] isFileURL])
                pe = [[FilePlaylistEntry alloc] init];
            else
                pe = [[PlaylistEntry alloc] init];
            
            [pe setValuesForKeysWithDictionary:entry];
            pe.index = index+i;
            pe.queuePosition = -1;
            [entries addObject:pe];
            
            ++i;
        }
    }
	
	NSIndexSet *is = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(index, [entries count])];
	
	[playlistController insertObjects:entries atArrangedObjectIndexes:is];

	if (xmlData && [[xmlData objectForKey:@"queue"] count])
    {
        [playlistController emptyQueueList:self];
        
        i = 0;
        for (NSNumber *index in [xmlData objectForKey:@"queue"])
        {
            int indexVal = [index intValue] + j;
            PlaylistEntry *pe = [entries objectAtIndex:indexVal];
            pe.queuePosition = i;
            pe.queued = YES;
            
            [[playlistController queueList] addObject:pe];
            
            ++i;
        }
    }
    
	//Clear the selection
	[playlistController setSelectionIndexes:nil];
	[self performSelectorInBackground:@selector(loadInfoForEntries:) withObject:entries];
	return entries;
}

- (void)loadInfoForEntries:(NSArray *)entries
{
    for (PlaylistEntry *pe in entries)
    {
        if ([pe metadataLoaded]) continue;
        
        __block PlaylistEntry *weakPe = pe;
        __block NSMutableDictionary *entryInfo = [NSMutableDictionary dictionaryWithCapacity:20];

        NSBlockOperation *op = [NSBlockOperation blockOperationWithBlock:^{
            NSDictionary *entryProperties = [AudioPropertiesReader propertiesForURL:weakPe.URL];
            if (entryProperties == nil)
                return;
            
            [entryInfo addEntriesFromDictionary:entryProperties];
            [entryInfo addEntriesFromDictionary:[AudioMetadataReader metadataForURL:weakPe.URL]];
        }];
        
        [op setCompletionBlock:^{
            [weakPe performSelectorOnMainThread:@selector(setMetadata:) withObject:entryInfo waitUntilDone:NO];
        }];
        
        [queue addOperation:op];
    }

	[queue waitUntilAllOperationsAreFinished];

	[playlistController performSelectorOnMainThread:@selector(updateTotalTime) withObject:nil waitUntilDone:NO];
}

- (void)clear:(id)sender
{
	[playlistController clear:sender];
}

- (NSArray*)addURLs:(NSArray *)urls sort:(BOOL)sort
{
	return [self insertURLs:urls atIndex:[[playlistController content] count] sort:sort];
}

- (NSArray*)addURL:(NSURL *)url
{
	return [self insertURLs:[NSArray arrayWithObject:url] atIndex:[[playlistController content] count] sort:NO];
}

- (NSArray *)acceptableFileTypes
{
	return [[self acceptableContainerTypes] arrayByAddingObjectsFromArray:[AudioPlayer fileTypes]];
}

- (NSArray *)acceptablePlaylistTypes
{
	return [NSArray arrayWithObjects:@"m3u", @"pls", nil];
}

- (NSArray *)acceptableContainerTypes
{
	return [AudioPlayer containerTypes];
}

- (void)willInsertURLs:(NSArray*)urls origin:(URLOrigin)origin
{
	[playlistController willInsertURLs:urls origin:origin];
}
- (void)didInsertURLs:(NSArray*)urls origin:(URLOrigin)origin
{
	[playlistController didInsertURLs:urls origin:origin];
}

@end
