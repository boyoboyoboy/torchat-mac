/*
 *  TCBuddy.cpp
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



#include <stdio.h>

#include <netdb.h>
#include <pwd.h>
#include <errno.h>
#include <sys/stat.h>

#include <Block.h>

#include <arpa/inet.h>
#include <sys/types.h>
#include <sys/socket.h>

#include "TCBuddy.h"

#include "TCConfig.h"
#include "TCTools.h"

#include "TCString.h"
#include "TCImage.h"
#include "TCNumber.h"

#include "TCFileSend.h"
#include "TCFileReceive.h"



/*
** Defines
*/
#pragma mark - Defines

#define TORCHAT_PORT	11009 // Should be in config file ?



/*
** Types
*/
#pragma mark - Types

// == Structure representing a Socks connection request ==
struct sockreq
{
	uint8_t		version;
	uint8_t		command;
	uint16_t	dstport;
	uint32_t	dstip;
	// A null terminated username goes here
};

// == Structure representing a Socks connection request response ==
struct sockrep
{
	uint8_t		version;
	uint8_t		result;
	uint16_t	ignore1;
	uint32_t	ignore2;
};

// == Socks State ==
typedef enum
{
	socks_nostate,
	socks_running,
	socks_finish,
} socks_state;	

// == Socks trame type ==
typedef enum
{
	socks_v4_reply,
} socks_trame;



/*
** Global
*/
#pragma mark - Global

static char gQueueIdentityKey;
static char gMainQueueContext;




/*
** TCBuddy - Instance
*/
#pragma mark - TCBuddy - Instance

TCBuddy::TCBuddy(id <TCConfig>_config, const std::string &_alias, const std::string &_address, const std::string &_notes)
{	
	// Retain config
	config = _config;
	
	// Retain property
	malias = new TCString(_alias);
	maddress = new TCString(_address);
	mnotes = new TCString(_notes);
	
	fsend = [[NSMutableDictionary alloc] init];
	freceive = [[NSMutableDictionary alloc] init];

	TCDebugLog("Buddy (%s) - New", maddress->content().c_str());

	// Build queue
	mainQueue = dispatch_queue_create("com.torchat.core.buddy.main", DISPATCH_QUEUE_SERIAL);
	
	dispatch_queue_set_specific(mainQueue, &gQueueIdentityKey, &gMainQueueContext, NULL);

	// Init notice queue & block
	nQueue = 0;
	nBlock = 0;
	
	// Init status
	running = false;
	ponged = false;
	pongSent = false;
	
	outSocket = NULL;
	inSocket = NULL;
	
	socksstate = socks_nostate;
	mstatus = tcbuddy_status_offline;
	
	// Init profiles
	profileName = new TCString("");
	profileText = new TCString("");
	profileAvatar = [[TCImage alloc] initWithWidth:64 andHeight:64];
		
	// Init remotes
	peerClient = new TCString("");
	peerVersion = new TCString("");
	
	// Generate random
	char	rnd[101];
	char	charset [] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
	size_t	i;
	size_t	index;
	
	srandomdev();
	
	for (i = 0; i < sizeof(rnd) - 1; i++)
	{
		index = (unsigned long)random() % (sizeof(charset) - 1);
		rnd[i] = charset[index];
	}
	
	rnd[100] = '\0';
	
	mrandom = new TCString(rnd);
}

TCBuddy::~TCBuddy()
{
	TCDebugLog("TCBuddy Destructor");
	
	// Clean out connections
	if (outSocket)
	{
		[outSocket stop];
		outSocket = nil;
	}
	
	// Clean in connexions
	if (inSocket)
	{
		[inSocket stop];
		inSocket = nil;
	}
	
	// Release config
	config = nil;
	
	// Release property
	malias->release();
	maddress->release();
	mnotes->release();
	mrandom->release();
	
	// Release profile
	profileName->release();
	profileText->release();
	profileAvatar = nil;
	
	// Release
	peerClient->release();
	peerVersion->release();
	
	// Clean.
	fsend = nil;
	freceive = nil;
}



/*
** TCBuddy - Running
*/
#pragma mark - TCBuddy - Running

void TCBuddy::start()
{
	dispatch_async_cpp(this, mainQueue, ^{
		
		if (running)
			return;
		
		if (mblocked)
			return;
		
		TCDebugLog( "Buddy (%s) - Start", maddress->content().c_str());
		
		// -- Make a connection to Tor proxy --
		struct addrinfo	hints, *res, *res0;
		int				error;
		int				s;
		char			sport[50];
		
		memset(&hints, 0, sizeof(hints));
		
		snprintf(sport, sizeof(sport), "%i", [config torPort]);
		
		// Configure the resolver
		hints.ai_family = PF_UNSPEC;
		hints.ai_socktype = SOCK_STREAM;

		// Try to resolve and connect to the given address
		error = getaddrinfo([[config torAddress] UTF8String], sport, &hints, &res0);
		if (error)
		{
			_error(tcbuddy_error_resolve_tor, "core_bd_err_tor_resolve", true);
			return;
		}
		
		s = -1;
		for (res = res0; res; res = res->ai_next)
		{
			if ((s = socket(res->ai_family, res->ai_socktype, res->ai_protocol)) < 0)
				continue;
			
			if (connect(s, res->ai_addr, res->ai_addrlen) < 0)
			{
				close(s);
				s = -1;
				
				continue;
			}
			
			break;
		}
		
		freeaddrinfo(res0);
		
		if (s < 0)
		{
			_error(tcbuddy_error_connect_tor, "core_bd_err_tor_connect", true);
			return;
		}
		
		// Build a socket with this descriptor
		outSocket = [[TCSocket alloc] initWithSocket:s];
		
		
		// Set ourself as delegate
#warning FIXME: fix when switched to OC.
		//outSocket->setDelegate(mainQueue, this);
		
		// Start SOCKS protocol
		_startSocks();

		// Set as running
		running = true;
		
		// Say that we are connected
		_notify(tcbuddy_notify_connected_tor, "core_bd_note_tor_connected");
	});
}

void TCBuddy::stop()
{
	dispatch_async_cpp(this, mainQueue, ^{

		if (running)
		{
			tcbuddy_status lstatus;
			
			// Realease out socket
			if (outSocket)
			{
				[outSocket stop];
				outSocket = nil;
			}
			
			// Realease in socket
			if (inSocket)
			{
				[inSocket stop];
				inSocket = nil;
			}
			
			// Clean receive session
			[freceive removeAllObjects];
			
			// Clean send session
			[fsend removeAllObjects];
			
			// Reset status
			lstatus = mstatus;
			mstatus = tcbuddy_status_offline;
			
			socksstate = socks_nostate;
			ponged = false;
			pongSent = false;
			running = false;
			
			// Notify
			if (lstatus != tcbuddy_status_offline)
			{
				TCNumber *tstatus = _status();
				
				_notify(tcbuddy_notify_status, "core_bd_note_status_changed", tstatus);
				
				tstatus->release();
			}
			
			_notify(tcbuddy_notify_disconnected, "core_bd_note_stoped");
		}
	});
}

bool TCBuddy::isRunning()
{
	__block bool result = false;
	
	dispatch_sync_cpp(this, mainQueue, ^{
		result = running;
	});
	
	return result;
}

bool TCBuddy::isPonged()
{
	__block bool result = false;
	
	dispatch_sync_cpp(this, mainQueue, ^{
		result = ponged;
	});
	
	return result;
}


void TCBuddy::keepAlive()
{
	dispatch_async_cpp(this, mainQueue, ^{
		
		if (mblocked)
			return;
		
		if (!running)
			start();
		else
		{
			if (pongSent && ponged)
				_sendStatus(cstatus);
		}
	});
}


/*
** TCBuddy - Delegate
*/
#pragma mark - TCBuddy - Delegate

void TCBuddy::setDelegate(dispatch_queue_t queue, tcbuddy_event event)
{
	// Asign on a block
	dispatch_async_cpp(this, mainQueue, ^{
		nQueue = queue;
		nBlock = event;
	});
}



/*
** TCBuddy - Accessors
*/
#pragma mark - TCBuddy - Accessor

TCString * TCBuddy::alias()
{
	__block TCString *result = NULL;
	
	dispatch_sync_cpp(this, mainQueue, ^{
		
		malias->retain();
		
		result = malias;
	});
	
	return result;
}

void TCBuddy::setAlias(TCString *alias)
{
	if (!alias)
		return;
	
	alias->retain();
	
	dispatch_async_cpp(this, mainQueue, ^{
		
		// Set the new name in config
		[config setBuddy:@(maddress->content().c_str()) alias:@(alias->content().c_str())];
		
		// Change the name internaly
		malias->release();
		malias = alias;
		
		// Notidy of the change
		_notify(tcbuddy_notify_alias, "core_bd_note_alias_changed", malias);
	});
}

TCString * TCBuddy::notes()
{
	__block TCString *result = NULL;
	
	dispatch_sync_cpp(this, mainQueue, ^{
		
		mnotes->retain();
		
		result = mnotes;
	});
	
	return result;
}

void TCBuddy::setNotes(TCString *notes)
{
	if (!notes)
		return;
	
	notes->retain();
	
	dispatch_async_cpp(this, mainQueue, ^{
		
		// Set the new name in config
		[config setBuddy:@(maddress->content().c_str()) notes:@(notes->content().c_str())];
		
		// Change the name internaly
		mnotes->release();
		mnotes = notes;
		
		// Notify of the change
		_notify(tcbuddy_notify_notes, "core_bd_note_notes_changed", mnotes);
	});
}

bool TCBuddy::blocked()
{
	// Prevent dead-lock
	if (dispatch_get_specific(&gQueueIdentityKey) == &gMainQueueContext)
	{
		return mblocked;
	}
	else
	{
		__block bool isblocked = false;
		
		dispatch_sync_cpp(this, mainQueue, ^{
			
			isblocked = mblocked;
		});
		
		return isblocked;
	}
}

void TCBuddy::setBlocked(bool blocked)
{
	dispatch_async_cpp(this, mainQueue, ^{
		
		TCNumber *blk = new TCNumber((uint8_t)blocked);
		
		mblocked = blocked;
		
		// Notify of the change
		_notify(tcbuddy_notify_blocked, "core_bd_note_blocked_changed", blk);
		
		// Clean
		blk->release();
	});
}

tcbuddy_status TCBuddy::status()
{
	__block tcbuddy_status res = tcbuddy_status_offline;
	
	dispatch_sync_cpp(this, mainQueue, ^{
		
		if (pongSent && ponged)
			res = mstatus;
		else
			res = tcbuddy_status_offline;
	});
					  
	return res;
}



/*
** TCBuddy - Files Info
*/
#pragma mark - TCBuddy - Files Info

std::string TCBuddy::fileFileName(const std::string &uuid, tcbuddy_file_way way)
{
	std::string			*c_uuid = new std::string(uuid);
	__block std::string res;
	
	dispatch_sync_cpp(this, mainQueue, ^{
		
		if (way == tcbuddy_file_send)
		{
			TCFileSend *file = fsend[@(c_uuid->c_str())];
			
			if (file)
				res = [[file fileName] UTF8String];
		}
		else if (way == tcbuddy_file_receive)
		{
			TCFileReceive *file = freceive[@(c_uuid->c_str())];
			
			if (file)
				res = [[file fileName] UTF8String];
		}
		
		delete c_uuid;
	});
	
	return res;
}

std::string TCBuddy::fileFilePath(const std::string &uuid, tcbuddy_file_way way)
{
	std::string			*c_uuid = new std::string(uuid);
	
	__block std::string res;
	
	dispatch_sync_cpp(this, mainQueue, ^{
		
		if (way == tcbuddy_file_send)
		{
			TCFileSend *file = fsend[@(c_uuid->c_str())];

			res = [[file filePath] UTF8String];
		}
		else if (way == tcbuddy_file_receive)
		{
			TCFileReceive *file = freceive[@(c_uuid->c_str())];

			if (file)
				res = [[file filePath] UTF8String];
		}
		
		delete c_uuid;
	});
	
	return res;
}

bool TCBuddy::fileStat(const std::string &uuid, tcbuddy_file_way way, uint64_t &done, uint64_t &total)
{
	std::string		*c_uuid = new std::string(uuid);
	
	__block bool		result = false;
	__block uint64_t	rdone = 0;
	__block uint64_t	rtotal = 0;
	
	
	dispatch_sync_cpp(this, mainQueue, ^{
		
		if (way == tcbuddy_file_send)
		{
			// Search the file send
			TCFileSend *file = fsend[@(c_uuid->c_str())];

			if (file)
			{
				rdone = [file validatedSize];
				rtotal = [file fileSize];
				
				result = true;
			}
		}
		else if (way == tcbuddy_file_receive)
		{
			TCFileReceive *file = freceive[@(c_uuid->c_str())];

			if (file)
			{
				rdone = [file receivedSize];
				rtotal = [file fileSize];
				
				result = true;
			}
		}
		
		delete c_uuid;
	});
	
	// Give values
	done = rdone;
	total = rtotal;
	
	// Return result
	return result;
}

void TCBuddy::fileCancel(const std::string &uuid, tcbuddy_file_way way)
{
	std::string *c_uuid = new std::string(uuid);
	
	dispatch_async_cpp(this, mainQueue, ^{
		
		if (way == tcbuddy_file_send)
		{
			// Search the file send
			TCFileSend *file = fsend[@(c_uuid->c_str())];

			if (file)
			{
				// Say to the remote peer to stop receiving data
				_sendFileStopReceiving(*c_uuid);
				
				// Notify that we stop sending the file
				TCFileInfo *info = new TCFileInfo(file);
				
				_notify(tcbuddy_notify_file_send_stoped, "core_bd_note_file_send_canceled", info);

				info->release();
				
				// Release file
				[fsend removeObjectForKey:@(c_uuid->c_str())];
			}
		}
		else if (way == tcbuddy_file_receive)
		{
			TCFileReceive *file = freceive[@(c_uuid->c_str())];
			
			if (file)
			{
				// Say to the remote peer to stop sending data
				_sendFileStopSending(*c_uuid);
				
				// Notify that we stop sending the file
				TCFileInfo *info = new TCFileInfo(file);

				_notify(tcbuddy_notify_file_receive_stoped, "core_bd_note_file_receive_canceled", info);
				
				info->release();
				
				// Release file
				[freceive removeObjectForKey:@(c_uuid->c_str())];
			}
		}
		
		delete c_uuid;
	});
}



/*
** TCBuddy - Send Command
*/
#pragma mark - TCBuddy - Send Command

void TCBuddy::sendStatus(tccontroller_status status)
{
	dispatch_async_cpp(this, mainQueue, ^{
		
		// Send status only if we are ponged
		if (pongSent && !mblocked)		
			_sendStatus(status);
	});
}

void TCBuddy::sendAvatar(TCImage *avatar)
{
	if (!avatar)
		return;
	
	dispatch_async_cpp(this, mainQueue, ^{

		if (pongSent && ponged && !mblocked)		
			_sendAvatar(avatar);
	});
}

void TCBuddy::sendProfileName(TCString *name)
{
	if (!name)
		return;
	
	name->retain();
	
	dispatch_async_cpp(this, mainQueue, ^{

		if (pongSent && ponged && !mblocked)
			_sendProfileName(name);
		
		name->release();
	});
}

void TCBuddy::sendProfileText(TCString *text)
{
	if (!text)
		return;
	
	text->retain();
	
	dispatch_async_cpp(this, mainQueue, ^{
		
		if (pongSent && ponged && !mblocked)
			_sendProfileText(text);
		
		text->release();
	});
}

void TCBuddy::sendMessage(TCString *message)
{
	if (!message)
		return;
	
	message->retain();
	
	dispatch_async_cpp(this, mainQueue, ^{
		
		if (!mblocked)
		{
			// Send Message only if we sent pong and we are ponged
			if (pongSent && ponged)
				_sendCommand("message", message);
			else
				_error(tcbuddy_error_message_offline, "core_bd_err_message_offline", message, false);
		}
		else
			_error(tcbuddy_error_message_blocked, "core_bd_err_message_blocked", message, false);

		message->release();
	});
}

void TCBuddy::sendFile(TCString *filepath)
{
	if (!filepath)
		return;
	
	filepath->retain();
		
	dispatch_async_cpp(this, mainQueue, ^{

		// Send file only if we sent pong and we are ponged
		if (pongSent && ponged)
		{
			if (!mblocked)
			{
				TCFileSend *file;
				
				// Try to open the file for send
				NSString *fpath = @(filepath->content().c_str());
				
				file = [[TCFileSend alloc] initWithFilePath:fpath];
				
				if (!file)
				{
					_error(tcbuddy_error_send_file, "io_error", filepath, false);
#warning FIXME: localized string.
					
					filepath->release();
					return;
				}
				
				// Insert the new file session
				fsend[[file uuid]] = file;
				
				// Notify
				TCFileInfo *info = new TCFileInfo(file);
				
				_notify(tcbuddy_notify_file_send_start, "core_bd_note_file_send_start", info);
				
				info->release();
				
				// Start the file session
				_sendFileName(file);
				
				// Send the first block to start the send
				_sendFileData(file);
			}
			else
				_error(tcbuddy_error_file_blocked, "core_bd_err_file_blocked", filepath, false);
		}
		else
		{
			_error(tcbuddy_error_file_offline, "core_bd_err_file_offline", filepath, false);
		}
		
		// Release
		filepath->release();
	});
}



/*
** TCBuddy - Action
*/
#pragma mark - TCBuddy - Action

void TCBuddy::startHandshake(TCString *rrandom, tccontroller_status status, TCImage *avatar, TCString *name, TCString *text)
{
	if (!rrandom || !avatar || !name || !text)
		return;
		
	rrandom->retain();
	name->retain();
	text->retain();
	
	dispatch_async_cpp(this, mainQueue, ^{
		
		if (!mblocked)
		{
			_sendPong(rrandom);
			_sendClient();
			_sendVersion();
			_sendProfileName(name);
			_sendProfileText(text);
			_sendAvatar(avatar);
			_sendAddMe();
			_sendStatus(status);
			
			pongSent = true;
		}
		
		rrandom->release();
		name->release();
		text->release();
	});
}

void TCBuddy::setInputConnection(TCSocket *sock)
{
	if (!sock)
		return;
		
	dispatch_async_cpp(this, mainQueue, ^{
		
		if (mblocked)
		{
			[sock stop];
		}
		else
		{
			// Activate send message & send file commands
			ponged = true;
			
			// Use this incomming connection
#warning FIXME: use self when switched to OC.
#warning XXX: check that we will not loose event during this change.
			//sock->setDelegate(mainQueue, this);
			
			if (inSocket)
				[inSocket stop];
			
			inSocket = sock;
			
			[inSocket setGlobalOperation:tcsocket_op_line withSize:0 andTag:0];
			
			// Notify that we are ready
			if (ponged && pongSent)
				_notify(tcbuddy_notify_identified, "core_bd_note_identified");
		}
	});
}



/*
** TCBuddy(TCSocket) - Delegate
*/
#pragma mark - TCBuddy(TCSocket) - Delegate

void TCBuddy::socketOperationAvailable(TCSocket *socket, tcsocket_operation operation, int tag, void *content, size_t size)
{
#warning FIXME: use TCSocketDelegate once switched to OC.
	// > mainQueue <
	
	if (mblocked)
		return;
	
	if (operation == tcsocket_op_data)
	{
		// Get the reply
		struct sockrep *thisrep = static_cast<struct sockrep *> (content);
		
		// Check result
		switch (thisrep->result)
		{
			case 90: // Socks v4 protocol finish
			{
				socksstate = socks_finish;
				
				[outSocket setGlobalOperation:tcsocket_op_line withSize:0 andTag:0];
				
				// Notify
				_notify(tcbuddy_notify_connected_buddy, "core_bd_note_connected");
				
				// We are connected, do things
				_connectedSocks();
				
				break;
			}
				
			case 91:
				_error(tcbuddy_error_socks, "core_bd_err_socks_91", true);				
				break;
				
			case 92:
				_error(tcbuddy_error_socks, "core_bd_err_socks_92", true);
				break;
				
			case 93:
				_error(tcbuddy_error_socks, "core_bd_err_socks_93", true);
				break;
				
			default:
				_error(tcbuddy_error_socks, "core_bd_err_socks_unknown", true);
				break;
		}
		
		// Clean content
		free(content);
	}
	else if (operation == tcsocket_op_line)
	{
		std::vector <std::string *> *vect = static_cast< std::vector <std::string *> * > (content);
		size_t						i, cnt = vect->size();
		
		for (i = 0; i < cnt; i++)
		{
			std::string *line = vect->at(i);
			
			dispatch_async_cpp(this, mainQueue, ^{
				
				// Parse the line
#warning FIXME: use TCParser object once switched to OC
				//parseLine(*line);
				
				// Free memory
				delete line;
			});
		}
		
		// Clean
		delete vect;
	}
}

void TCBuddy::socketError(TCSocket *socket, TCInfo *err)
{
#warning FIXME: use TCSocketDelegate once switched to OC.

	// > mainQueue <
	
	// Localize the info
	err->setInfo([[config localized:@(err->info().c_str())] UTF8String]);
	
	// Fallback error
	_error(tcbuddy_error_socket, "core_bd_err_socket", err, true);
}

void TCBuddy::socketRunPendingWrite(TCSocket *socket)
{
#warning FIXME: use TCSocketDelegate once switched to OC.

	// > mainQueue <
	
	_runPendingWrite();
}



/*
** TCBuddy(TCParser) - Overwrite
*/
#pragma mark - TCBuddy(TCParser) - Overwrite

void TCBuddy::doStatus(const std::string &status)
{
	tcbuddy_status nstatus = tcbuddy_status_offline;
		
	if (status.compare("available") == 0)
		nstatus = tcbuddy_status_available;
	else if (status.compare("away") == 0)
		nstatus = tcbuddy_status_away;
	else if (status.compare("xa") == 0)
		nstatus = tcbuddy_status_xa;
	
	dispatch_async_cpp(this, mainQueue, ^{

		if (nstatus != mstatus && !mblocked)
		{
			mstatus = nstatus;
			
			// Notify that status changed
			TCNumber *tstatus = _status();
			
			_notify(tcbuddy_notify_status, "core_bd_note_status_changed", tstatus);
			
			tstatus->release();
		}
	});
}

void TCBuddy::doMessage(const std::string &message)
{
	TCString *amsg = new TCString(message);
	
	dispatch_async_cpp(this, mainQueue, ^{
		
		if (!mblocked)
		{
			// Notify it
			_notify(tcbuddy_notify_message, "core_bd_note_new_message", amsg);
		}
		
		// Release
		amsg->release();
	});
}

void TCBuddy::doVersion(const std::string &version)
{
	TCString *aversion = new TCString(version);
	
	dispatch_async_cpp(this, mainQueue, ^{
		
		peerVersion->release();
		peerVersion = aversion;
		
		// Notify it
		_notify(tcbuddy_notify_version, "core_bd_note_new_version", peerVersion);
	});
}

void TCBuddy::doClient(const std::string &client)
{
	TCString *aclient = new TCString(client);

	dispatch_async_cpp(this, mainQueue, ^{
		
		if (!mblocked)
		{
			peerClient->release();
			peerClient = aclient;
		
			// Notify it
			_notify(tcbuddy_notify_client, "core_bd_note_new_client", peerClient);
		}
		else
			aclient->release();
	});
}


void TCBuddy::doProfileText(const std::string &text)
{
	TCString *atext = new TCString(text);
	
	dispatch_async_cpp(this, mainQueue, ^{
		
		if (!mblocked)
		{
			profileText->release();
			profileText = atext;
				
			// Notify it
			_notify(tcbuddy_notify_profile_text, "core_bd_note_new_profile_text", profileText);
		}
		else
			atext->release();
	});
}

void TCBuddy::doProfileName(const std::string &name)
{
	TCString *aname = new TCString(name);

	dispatch_async_cpp(this, mainQueue, ^{
		
		if (!mblocked)
		{
			// Hold profile name
			profileName->release();
			profileName = aname;
		
			// Store profile name
			[config setBuddy:@(maddress->content().c_str()) lastProfileName:@(aname->content().c_str())];
		
			// Notify it
			_notify(tcbuddy_notify_profile_name, "core_bd_note_new_profile_name", profileName);
		}
		else
			aname->release();
	});
}

void TCBuddy::doProfileAvatar(const std::string &bitmap)
{
	std::string *abitmap = new std::string(bitmap);

	dispatch_async_cpp(this, mainQueue, ^{
		
		if (!mblocked)
		{
			[profileAvatar setBitmap:[[NSData alloc] initWithBytes:abitmap->data() length:abitmap->size()]];
		
			// Notify it
			_notify(tcbuddy_notify_profile_avatar, "core_bd_note_new_profile_avatar", (__bridge TCObject *)profileAvatar);
		}
		
		// Clean
		delete abitmap;
	});
}

void TCBuddy::doProfileAvatarAlpha(const std::string &bitmap)
{
	std::string *abitmap = new std::string(bitmap);

	dispatch_async_cpp(this, mainQueue, ^{
		
		if (!mblocked)
			[profileAvatar setBitmapAlpha:[[NSData alloc] initWithBytes:abitmap->data() length:abitmap->size()]];
		
		delete abitmap;
	});
}

void TCBuddy::doAddMe()
{
	/*
	 This must be sent after connection if you are (or want to be) 
	 on the other's buddy list. Since a client can also connect for 
	 the purpose of joining a chat room without automatically appearing 
	 on the buddy list this message is needed.
	*/
	
	// -> I will not for this fork. In futur, perhaps.
}

void TCBuddy::doRemoveMe()
{
	/*
	 when receiving this message the buddy MUST be removed from
	 the buddy list (or somehow marked as removed) so that it will not
	 automatically add itself again and cause annoyance. When removing
	 a buddy first send this message before disconnecting or the other
	 client will never know about it and add itself again next time"""
	*/
	
	
	// -> I will not for this fork. In futur, perhaps.
}

void TCBuddy::doFileName(const std::string &uuid, const std::string &fsize, const std::string &bsize, const std::string &filename)
{
	// Check if we are blocked
	if (blocked())
		return;
	
	// Quick check
	std::string *sfilename_1 = createReplaceAll(filename, "..", "_");
	std::string *sfilename_2 = createReplaceAll(*sfilename_1, "/", "_");
	
	
	// Get the download folder
	std::string down = [[config realPath:[config downloadFolder]] UTF8String];
	
	mkdir(down.c_str(), S_IRWXU | (S_IRGRP | S_IXGRP) | (S_IRWXO | S_IXOTH));
	
	
	// Build the final download path
	down = down + "/" + maddress->content() + "/";
	
	mkdir(down.c_str(), S_IRWXU | (S_IRGRP | S_IXGRP) | (S_IRWXO | S_IXOTH));
	
	
	// Parse values
	uint64_t	ifsize = strtoull(fsize.c_str(), NULL, 10);
	uint64_t	ibsize = strtoull(bsize.c_str(), NULL, 10);
	TCFileReceive *file;
	
	// Build a receiver instance
	file = [[TCFileReceive alloc] initWithUUID:@(uuid.c_str()) folder:@(down.c_str()) fileName:@(sfilename_2->c_str()) fileSize:ifsize blockSiz:ibsize];

	if (!file)
	{
		_error(tcbuddy_error_receive_file, "io_error", false);
#warning FIXME; add localized string
		return;
	}
	
	// Add it to the list
	dispatch_async_cpp(this, mainQueue, ^{
		
		freceive[[file uuid]] = file;
		
		TCFileInfo *info = new TCFileInfo(file);
		
		_notify(tcbuddy_notify_file_receive_start, "core_bd_note_file_receive_start", info);
		
		info->release();
	});

	// Clean
	delete sfilename_1;
	delete sfilename_2;
}

void TCBuddy::doFileData(const std::string &uuid, const std::string &start, const std::string &hash, const std::string &data)
{
	/*
	 TorChat protocol is based on text token protocol ("filedata", "filedata_ok", space separator, etc.).
	 TorChat Python use text function for this text protocol ("join", "split", "replace", etc.)
	 
	 If TorChat is well designed, the protocol _underlayer_ is not. Indeed, raw file data are sent
	 without encoding in this text protocol.
	 
	 When TorChat (Python) ask Python to do some text work on this data (like "replace"), Python try to
	 interpret them as UTF8 string before doing the job. On some rare case, when data contain a sequence
	 looking like UTF8 sequence but invalid, this interpretation fail and raise an un-handled exception.
	*/
	
	// Check if we are blocked
	if (blocked())
		return;
	
	std::string *c_uuid = new std::string(uuid);
	std::string *c_start = new std::string(start);
	std::string *c_hash = new std::string(hash);
	std::string *c_data = new std::string(data);
	
	// Manage file chunk
	dispatch_async_cpp(this, mainQueue, ^{
		
		TCFileReceive *file = freceive[@(c_uuid->c_str())];
		
		if (file)
		{
			uint64_t offset = strtoull(c_start->c_str(), NULL, 10);
			
			if ([file writeChunk:c_data->data() chunkSize:c_data->size() hash:@(c_hash->c_str()) offset:&offset])
			{
				// Send that this chunk is okay
				_sendFileDataOk(*c_uuid, offset);
				
				// Notify of the new chunk
				TCFileInfo *info = new TCFileInfo(file);
				
				_notify(tcbuddy_notify_file_receive_running, "core_bd_note_file_chunk_receive", info);

				// Do nothing if we are no more to send
				if ([file isFinished])
				{
					// Notify that we have finished
					_notify(tcbuddy_notify_file_receive_finish, "core_bd_note_file_receive_finish", info);

					// Release file
					[freceive removeObjectForKey:@(c_uuid->c_str())];
				}
				
				// Release info
				info->release();
			}
			else
				_sendFileDataError(*c_uuid, offset);
		}
		else
		{
			_sendFileStopSending(*c_uuid);
		}
		
		// Clean
		delete c_uuid;
		delete c_start;
		delete c_hash;
		delete c_data;
	});
}


void TCBuddy::doFileDataOk(const std::string &uuid, const std::string &start)
{
	// Check if we are blocked
	if (blocked())
		return;
	
	std::string *c_uuid = new std::string(uuid);
	std::string *c_start = new std::string(start);
	
	// Manage file chunk
	dispatch_async_cpp(this, mainQueue, ^{
		
		TCFileSend *file = fsend[@(c_uuid->c_str())];

		if (file)
		{
			uint64_t offset = strtoull(c_start->c_str(), NULL, 10);
			
			// Inform that this offset was validated
			[file setValidatedOffset:offset];
			
			// Notice the advancing
			TCFileInfo *info = new TCFileInfo(file);
			
			_notify(tcbuddy_notify_file_send_running, "core_bd_note_file_chunk_send", info);
			
			// Do nothing if we are no more to send
			if ([file isFinished])
			{
				// Notify
				_notify(tcbuddy_notify_file_send_finish, "core_bd_note_file_send_finish", info);
				
				// Release the file
				[fsend removeObjectForKey:@(c_uuid->c_str())];
			}
			else
				_runPendingFileWrite();
			
			// Release info
			info->release();
		}
		else
		{
			_sendFileStopReceiving(*c_uuid);
		}
		
		// Clean
		delete c_uuid;
		delete c_start;
	});
}

void TCBuddy::doFileDataError(const std::string &uuid, const std::string &start)
{
	// Check if we are blocked
	if (blocked())
		return;
	
	std::string *c_uuid = new std::string(uuid);
	std::string *c_start = new std::string(start);

	// Manage file chunk
	dispatch_async_cpp(this, mainQueue, ^{

		TCFileSend *file = fsend[@(c_uuid->c_str())];
		
		if (file)
		{
			uint64_t offset = strtoull(c_start->c_str(), NULL, 10);
			
			// Set the position where we should re-send
			[file setNextChunkOffset:offset];
		}
		else
		{
			_sendFileStopReceiving(*c_uuid);
		}
		
		// Clean
		delete c_uuid;
		delete c_start;
	});
}

void TCBuddy::doFileStopSending(const std::string &uuid)
{
	// Check if we are blocked
	if (blocked())
		return;
	
	std::string *c_uuid = new std::string(uuid);
	
	// Manage file chunk
	dispatch_async_cpp(this, mainQueue, ^{
		
		TCFileSend *file = fsend[@(c_uuid->c_str())];
		
		if (file)
		{
			// Notify that we stop sending the file
			TCFileInfo *info = new TCFileInfo(file);
			
			_notify(tcbuddy_notify_file_send_stoped, "core_bd_note_file_send_stoped", info);
			
			info->release();

			// Release file
			[fsend removeObjectForKey:@(c_uuid->c_str())];
		}
		
		// Clean
		delete c_uuid;
	});
}

void TCBuddy::doFileStopReceiving(const std::string &uuid)
{
	// Check if we are blocked
	if (blocked())
		return;
	
	std::string *c_uuid = new std::string(uuid);
	
	// Manage file chunk
	dispatch_async_cpp(this, mainQueue, ^{
		
		TCFileSend *file = fsend[@(c_uuid->c_str())];
		
		if (file)
		{
			// Notify that we stop receiving the file
			TCFileInfo *info = new TCFileInfo(file);
			
			_notify(tcbuddy_notify_file_receive_stoped, "core_bd_note_file_receive_stoped", info);
			
			info->release();
			
			// Release file
			[freceive removeObjectForKey:@(c_uuid->c_str())];
		}
		
		// Clean
		delete c_uuid;
	});
}

void TCBuddy::parserError(TCInfo *err)
{
	if (!err)
		return;
	
	err->retain();
	
	dispatch_async_cpp(this, mainQueue, ^{
		
		// Don't get parse error on blocked buddy (prevent spam, etc.)
		if (!mblocked)
			_error(tcbuddy_error_parse, "core_bd_err_parse", err, false);
		
		err->release();
	});
}



/*
** TCBuddy - Content
*/
#pragma mark - TCBuddy - Content

TCString * TCBuddy::getProfileText()
{
	__block TCString * result = NULL;
	
	dispatch_sync_cpp(this, mainQueue, ^{
		
		profileText->retain();
		result = profileText;
	});
	
	return result;
}

TCImage * TCBuddy::getProfileAvatar()
{
	__block TCImage * result = NULL;
	
	dispatch_sync_cpp(this, mainQueue, ^{
		result = profileAvatar;
	});

	return result;
}


TCString * TCBuddy::getProfileName()
{
	__block TCString * result = NULL;
	
	dispatch_sync_cpp(this, mainQueue, ^{
		
		profileName->retain();
		result = profileName;
	});
	
	return result;
}

TCString * TCBuddy::getLastProfileName()
{
	__block TCString *result = NULL;
	
	dispatch_sync_cpp(this, mainQueue, ^{

		std::string value = [[config getBuddyLastProfileName:@(maddress->content().c_str())] UTF8String];
		
		result = new TCString(value);
	});
	
	return result;
}

TCString * TCBuddy::getFinalName()
{
	__block TCString *result = NULL;
	
	dispatch_sync_cpp(this, mainQueue, ^{
		
		if (malias->content().length() > 0)
		{
			malias->retain();
		
			result = malias;
		}
		else if (profileName->content().length() > 0)
		{
			profileName->retain();
			
			result = profileName;
		}
		else
		{
			std::string value = [[config getBuddyLastProfileName:@(maddress->content().c_str())] UTF8String];
			
			result = new TCString(value);
		}
	});
	
	return result;
}



/*
** TCBuddy - Send Low Command
*/
#pragma mark - TCBuddy - Send Low Command

void TCBuddy::_sendPing()
{
	// > mainQueue <
	
	std::vector <std::string> items;
	
	items.push_back([[config selfAddress] UTF8String]);
	items.push_back(mrandom->content());
	
	_sendCommand("ping", items);
}

void TCBuddy::_sendPong(TCString *random)
{
	// > mainQueue <
	
	if (!random)
		return;
	
    _sendCommand("pong", random);
}

void TCBuddy::_sendStatus(tccontroller_status status)
{
	// > mainQueue <
	cstatus = status;
	
	switch (status)
	{
		case tccontroller_available:
			_sendCommand("status", "available");
			break;
			
		case tccontroller_away:
			_sendCommand("status", "away");
			break;
			
		case tccontroller_xa:
			_sendCommand("status", "xa");
			break;
	}
}

void TCBuddy::_sendMessage(const std::string &message)
{
	// > mainQueue <
	
	_sendCommand("message", message);
}

void TCBuddy::_sendVersion()
{
	// > mainQueue <
	
	_sendCommand("version", [[config clientVersion:tc_config_get_real] UTF8String]);
}

void TCBuddy::_sendClient()
{
	// > mainQueue <
	
	_sendCommand("client",  [[config clientName:tc_config_get_real] UTF8String]);
}

void TCBuddy::_sendProfileName(TCString *name)
{
	// > mainQueue <

	if (!name)
		return;
	
	_sendCommand("profile_name", name);
}

void TCBuddy::_sendProfileText(TCString *text)
{
	// > mainQueue <

	if (!text)
		return;
	
	_sendCommand("profile_text", text);
}

void TCBuddy::_sendAvatar(TCImage *avatar)
{
	// > mainQueue <

	std::vector <std::string> items;
	
	if (!avatar)
		return;
	
	if ([avatar bitmapAlpha])
	{
		std::string data((char *)[[avatar bitmapAlpha] bytes], [[avatar bitmapAlpha] length]);
		
		_sendCommand("profile_avatar_alpha", data);
	}

	if ([avatar bitmap])
	{
		std::string data((char *)[[avatar bitmap] bytes], [[avatar bitmap] length]);
		
		_sendCommand("profile_avatar", data);
	}
	else
		_sendCommand("profile_avatar");
}

void TCBuddy::_sendAddMe()
{
	// > mainQueue <
	
	_sendCommand("add_me");
}

void TCBuddy::_sendFileName(TCFileSend *file)
{
	// > mainQueue <
	
	if (!file)
		return;
	
	std::vector <std::string> items;
	
	char		buffer[1024];
	
	// Add the uuid
	items.push_back(std::string([[file uuid] UTF8String]));
	
	// Add the file size
	snprintf(buffer, sizeof(buffer), "%llu", [file fileSize]);
	items.push_back(std::string(buffer));
	
	// Add the block size
	snprintf(buffer, sizeof(buffer), "%u", [file blockSize]);
	items.push_back(std::string(buffer));
	
	// Add the filename
	items.push_back(std::string([[file fileName] UTF8String]));
		
	// Send the command
	_sendCommand("filename", items, tcbuddy_channel_in);
}

void TCBuddy::_sendFileData(TCFileSend *file)
{
	// > mainQueue <
	
	if (!file)
		return;
	
	uint8_t		chunk[[file blockSize]];
	uint64_t	chunksz = 0;
	uint64_t	offset = 0;
	NSString	*md5String;
	
	//
	md5String = [file readChunk:chunk chunkSize:&chunksz fileOffset:&offset];
	
	if (!md5String)
		return;
	
	//
	std::string	*md5 = NULL;

	md5 = new std::string([md5String UTF8String]);
	
	//
	std::vector <std::string>	items;
	char						buffer[50];
	
	// Add UUID
	items.push_back([[file uuid] UTF8String]);
	
	// Add the offset
	snprintf(buffer, sizeof(buffer), "%llu", offset);
	items.push_back(buffer);
	
	// Add the MD5
	items.push_back(*md5);
	delete md5;
	
	// Add the data
	std::string chk((char *)chunk, static_cast <size_t>(chunksz));
	items.push_back(chk);
	
	// Send the chunk
	_sendCommand("filedata", items, tcbuddy_channel_in);
	
}

void TCBuddy::_sendFileDataOk(const std::string &uuid, uint64_t start)
{
	// > mainQueue <
	
	std::vector<std::string>	items;
	char						buffer[100];
	
	// Add UUID
	items.push_back(uuid);
	
	// Add the offset
	snprintf(buffer, sizeof(buffer), "%llu", start);
	
	items.push_back(buffer);
	
	
	// Send the command
	_sendCommand("filedata_ok", items);
}

void TCBuddy::_sendFileDataError(const std::string &uuid, uint64_t start)
{
	// > mainQueue <
	
	std::vector<std::string>	items;
	char						buffer[100];
	
	// Add UUID
	items.push_back(uuid);
	
	// Add the offset
	snprintf(buffer, sizeof(buffer), "%llu", start);
	
	items.push_back(buffer);
	
	// Send the command
	_sendCommand("filedata_error", items);
}

void TCBuddy::_sendFileStopSending(const std::string &uuid)
{
	// > mainQueue <
	
	_sendCommand("file_stop_sending", uuid);
}

void TCBuddy::_sendFileStopReceiving(const std::string &uuid)
{
	// > mainQueue <
	
	_sendCommand("file_stop_receiving", uuid);
}



/*
** TCBuddy - Send Command Data
*/
#pragma mark - TCBuddy - Send Command Data

bool TCBuddy::_sendCommand(const std::string &command, tcbuddy_channel channel)
{
	// > mainQueue <
	
	return _sendCommand(command, "", channel);
}

bool TCBuddy::_sendCommand(const std::string &command, const std::vector<std::string> &data, tcbuddy_channel channel)
{
	// > mainQueue <
	
	std::string *result = createJoin(data, " ");
	bool		bresult;

	// Send the command
	bresult = _sendCommand(command, *result, channel);
	
	// Clean
	delete result;
	
	return bresult;
}

bool TCBuddy::_sendCommand(const std::string &command, TCString *data, tcbuddy_channel channel)
{
	if (!data)
		return false;
	
	return _sendCommand(command, data->content(), channel);
}


bool TCBuddy::_sendCommand(const std::string &command, const std::string &data, tcbuddy_channel channel)
{
	// > mainQueue <
	
	// -- Build the command line --
	std::string *part = new std::string(command);
	
	if (data.size() > 0)
	{
		part->append(" ");
		part->append(data);
	}
	
	// Escape protocol special chars
	std::string *l1 = createReplaceAll(*part, "\\", "\\/");
	std::string *l2 = createReplaceAll(*l1, "\n", "\\n");
		
	l2->append("\n");
	
	delete part;
	delete l1;

	// -- Buffer or send the command --
	if (socksstate != socks_finish)
	{
		bufferedCommands.push_back(l2);
		
		if (!running)
			start();
	}
	else
	{
		_sendData(l2->data(), l2->size(), channel);
		delete l2;
	}
	
	return true;
}

bool TCBuddy::_sendData(const void *data, size_t size, tcbuddy_channel channel)
{
	// > mainQueue <
	
	if (!data || size == 0)
		return false;

	void *cpy = malloc(size);
	
	if (!cpy)
		return false;
	
	memcpy(cpy, data, size);

	if (channel == tcbuddy_channel_in && inSocket)
		[inSocket sendBytes:cpy ofSize:size copy:NO];
	else if (channel == tcbuddy_channel_out && outSocket)
		[outSocket sendBytes:cpy ofSize:size copy:NO];
	else
		free(cpy);

	return true;
}



/*
** TCBuddy - Network Helper
*/
#pragma mark - TCBuddy - Network Helper

void TCBuddy::_startSocks()
{
	// > mainQueue <
	
	const char			*user = "torchat";
	struct sockreq		*thisreq;
	char				*buffer;
	size_t				datalen;
	
	// Get the target connexion informations
	std::string host = maddress->content() + ".onion";

	// Check data size
	datalen = sizeof(struct sockreq) + strlen(user) + 1;
	datalen += strlen(host.c_str()) + 1;
	
	buffer = (char *)malloc(datalen);
	thisreq = (struct sockreq *)buffer;
	
	// Create the request
	thisreq->version = 4;
	thisreq->command = 1;
	thisreq->dstport = htons(TORCHAT_PORT);
	thisreq->dstip = htonl(0x00000042); // Socks v4a
	
	// Copy the username
	strcpy((char *)thisreq + sizeof(struct sockreq), user);
	
	// Socks v4a : set the host name if we cant resolve it
	char *pos = (char *)thisreq + sizeof(struct sockreq);
	
	pos += strlen(user) + 1;
	strcpy(pos, host.c_str());
	
	// Set the next input operation
	[outSocket scheduleOperation:tcsocket_op_data withSize:sizeof(struct sockrep) andTag:socks_v4_reply];
	
	// Send the request
	if (_sendData(buffer, datalen))
		socksstate = socks_running;
	else
		_error(tcbuddy_error_socks, "core_bd_err_socks_request", true);
	
	free(buffer);
}

void TCBuddy::_connectedSocks()
{
	// > mainQueue <
	
	// -- Send ping --
	_sendPing();
	
	// -- Send buffered commands --
	size_t i, cnt = bufferedCommands.size();
	
	for (i = 0; i < cnt; i++)
	{
		_sendData(bufferedCommands[i]->data(), bufferedCommands[i]->size());
		
		delete bufferedCommands[i];
	}
	
	bufferedCommands.clear();
}

// There is place to write, so... write
void TCBuddy::_runPendingWrite()
{
	// > mainQueue <
	
	// Try to send pending files send
	_runPendingFileWrite();
}

void TCBuddy::_runPendingFileWrite()
{
	// > mainQueue <
		
	// Send a block of each send file session
	for (NSString *uuid in fsend)
	{
		TCFileSend *file = fsend[uuid];
		
		if (([file readSize] - [file validatedSize]) >= 16 * [file blockSize])
			continue;
		
		_sendFileData(file);
	}
}



/*
** TCBuddy - Helper
*/
#pragma mark - TCBuddy - Helper

void TCBuddy::_error(tcbuddy_info code, const std::string &info, bool fatal)
{
	// > mainQueue <
	
	TCInfo *err = new TCInfo(tcinfo_error, code, [[config localized:@(info.c_str())] UTF8String]);
	
	_send_event(err);
	
	err->release();
	
	// Fatal -> stop
	if (fatal)
		stop();		
}

void TCBuddy::_error(tcbuddy_info code, const std::string &info, TCObject *ctx, bool fatal)
{
	// > mainQueue <
	
	TCInfo *err = new TCInfo(tcinfo_error, code, [[config localized:@(info.c_str())] UTF8String], ctx);
	
	_send_event(err);
	
	err->release();
	
	// Fatal -> stop
	if (fatal)
		stop();		
}

void TCBuddy::_error(tcbuddy_info code, const std::string &info, TCInfo *serr, bool fatal)
{
	// > mainQueue <
	
	TCInfo *err = new TCInfo(tcinfo_error, code, [[config localized:@(info.c_str())] UTF8String], serr);
	
	_send_event(err);
	
	err->release();
	
	// Fatal -> stop
	if (fatal)
		stop();	
}

void TCBuddy::_notify(tcbuddy_info notice)
{
	// > mainQueue <
	
	TCInfo *ifo = new TCInfo(tcinfo_info, notice);
	
	_send_event(ifo);
	
	ifo->release();
}

void TCBuddy::_notify(tcbuddy_info notice, const std::string &info)
{
	// > mainQueue <
	
	TCInfo *ifo = new TCInfo(tcinfo_info, notice, [[config localized:@(info.c_str())] UTF8String]);
	
	_send_event(ifo);
	
	ifo->release();
}

void TCBuddy::_notify(tcbuddy_info notice, const std::string &info, TCObject *ctx)
{
	// > mainQueue <
	
	TCInfo *ifo = new TCInfo(tcinfo_info, notice, [[config localized:@(info.c_str())] UTF8String], ctx);
	
	_send_event(ifo);
	
	ifo->release();
}

void TCBuddy::_send_event(TCInfo *info)
{
	// > mainQueue <
	
	if (!info)
		return;
	
	if (nQueue && nBlock)
	{
		info->retain();
		
		dispatch_async_cpp(this, nQueue, ^{
				
			nBlock(this, info);
				
			info->release();
		});
	}
}

TCNumber * TCBuddy::_status()
{
	// > mainQueue <
	
	tcbuddy_status res;
	
	if (pongSent && ponged)
		res = mstatus;
	else
		res = tcbuddy_status_offline;
	
	return new TCNumber((uint8_t) res);
}



/*
** TCFileInfo
*/
#pragma mark - TCFileInfo

// -- Constructor --
TCFileInfo::TCFileInfo(TCFileSend *_sender)
{
	if (!_sender)
		throw "NULL TCFileSend in TCFileInfo";
		
	sender = _sender;
	receiver = nil;
}

TCFileInfo::TCFileInfo(TCFileReceive *_receiver)
{
	if (!_receiver)
		throw "NULL TCFileSend in TCFileInfo";
		
	receiver = _receiver;
	sender = nil;
}

TCFileInfo::~TCFileInfo()
{
	sender = nil;
	receiver = nil;
	
	receiver = NULL;
}

// -- Property --
const std::string TCFileInfo::uuid()
{
	static std::string null;
	
	if (receiver)
		return [[receiver uuid] UTF8String];
	
	if (sender)
		return [[sender uuid] UTF8String];
	
	return null;
}

uint64_t TCFileInfo::fileSizeCompleted()
{
	if (receiver)
		return [receiver receivedSize];
	
	if (sender)
		return [sender validatedSize];
	
	return 0;
}

uint64_t TCFileInfo::fileSizeTotal()
{
	if (receiver)
		return [receiver fileSize];
	
	if (sender)
		return [sender fileSize];
	
	return 0;
}

const std::string TCFileInfo::fileName()
{
	static std::string null;
	
	if (receiver)
		return [[receiver fileName] UTF8String];
	
	if (sender)
		return [[sender fileName] UTF8String];
	
	return null;
}

const std::string TCFileInfo::filePath()
{
	static std::string null;

	if (receiver)
		return [[receiver filePath] UTF8String];
	
	if (sender)
		return [[sender filePath] UTF8String];
	
	return null;
}
