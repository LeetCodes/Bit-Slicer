/*
 * Created by Mayur Pawashe on 12/27/12.
 *
 * Copyright (c) 2012 zgcoder
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * Redistributions of source code must retain the above copyright notice,
 * this list of conditions and the following disclaimer.
 *
 * Redistributions in binary form must reproduce the above copyright
 * notice, this list of conditions and the following disclaimer in the
 * documentation and/or other materials provided with the distribution.
 *
 * Neither the name of the project's author nor the names of its
 * contributors may be used to endorse or promote products derived from
 * this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
 * HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED
 * TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
 * NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
 * SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "ZGDisassemblerController.h"
#import "ZGAppController.h"
#import "ZGProcess.h"
#import "ZGCalculator.h"
#import "ZGUtilities.h"
#import "ZGProcessList.h"
#import "ZGRunningProcess.h"
#import "ZGInstruction.h"
#import "udis86.h"
#import "ZGUtilities.h"

@interface ZGDisassemblerController ()

@property (assign) IBOutlet NSPopUpButton *runningApplicationsPopUpButton;
@property (assign) IBOutlet NSTextField *addressTextField;
@property (assign) IBOutlet NSTableView *instructionsTableView;
@property (assign) IBOutlet NSProgressIndicator *dissemblyProgressIndicator;
@property (assign) IBOutlet NSButton *stopButton;

@property (readwrite) ZGMemoryAddress currentMemoryAddress;
@property (readwrite) ZGMemorySize currentMemorySize;

@property (nonatomic, strong) NSArray *instructions;

@property (readwrite, strong, nonatomic) NSTimer *updateInstructionsTimer;
@property (readwrite, nonatomic) BOOL disassembling;
@property (readwrite, nonatomic) BOOL windowDidAppear;

@property (nonatomic, copy) NSString *desiredProcessName;

@property (nonatomic, strong) NSUndoManager *undoManager;

@end

#define ZGDisassemblerAddressField @"ZGDisassemblerAddressField"
#define ZGDisassemblerProcessName @"ZGDisassemblerProcessName"

@implementation ZGDisassemblerController

#pragma mark Birth & Death

- (id)init
{
	self = [super initWithWindowNibName:NSStringFromClass([self class])];
	
	self.undoManager = [[NSUndoManager alloc] init];
	
	return self;
}

- (void)encodeRestorableStateWithCoder:(NSCoder *)coder
{
    [super encodeRestorableStateWithCoder:coder];
	
	[coder encodeObject:self.addressTextField.stringValue forKey:ZGDisassemblerAddressField];
	[coder encodeObject:[self.runningApplicationsPopUpButton.selectedItem.representedObject name] forKey:ZGDisassemblerProcessName];
}

- (void)restoreStateWithCoder:(NSCoder *)coder
{
	[super restoreStateWithCoder:coder];
	
	NSString *disassemblerAddressField = [coder decodeObjectForKey:ZGDisassemblerAddressField];
	if (disassemblerAddressField)
	{
		self.addressTextField.stringValue = disassemblerAddressField;
	}
	
	self.desiredProcessName = [coder decodeObjectForKey:ZGDisassemblerProcessName];
	
	[self updateRunningProcesses];
	
	[self windowDidShow:nil];
}

- (void)markChanges
{
	if ([self respondsToSelector:@selector(invalidateRestorableState)])
	{
		[self invalidateRestorableState];
	}
}

- (void)setCurrentProcess:(ZGProcess *)newProcess
{
	BOOL shouldUpdate = NO;
	
	if (_currentProcess && _currentProcess.processID != newProcess.processID)
	{
		shouldUpdate = YES;
	}
	_currentProcess = newProcess;
	if (_currentProcess && ![_currentProcess hasGrantedAccess] && _currentProcess.processID != NON_EXISTENT_PID_NUMBER)
	{
		if (![_currentProcess grantUsAccess])
		{
			shouldUpdate = YES;
			//NSLog(@"Debugger failed to grant access to PID %d", _currentProcess.processID);
		}
	}
	
	if (shouldUpdate && self.windowDidAppear)
	{
		[self readMemory:nil];
	}
}

- (void)windowDidLoad
{
    [super windowDidLoad];
	
	self.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
	
	if ([self.window respondsToSelector:@selector(setRestorable:)] && [self.window respondsToSelector:@selector(setRestorationClass:)])
	{
		self.window.restorable = YES;
		self.window.restorationClass = ZGAppController.class;
		self.window.identifier = ZGDisassemblerIdentifier;
		[self markChanges];
	}
    
	// Add processes to popup button
	self.desiredProcessName = [[ZGAppController sharedController] lastSelectedProcessName];
	[self updateRunningProcesses];
	
	[[ZGProcessList sharedProcessList]
	 addObserver:self
	 forKeyPath:@"runningProcesses"
	 options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew
	 context:NULL];
}

// This is intended to be called when the window shows up - either from showWindow: or from window restoration
- (void)windowDidShow:(id)sender
{
	if (!self.updateInstructionsTimer)
	{
		self.updateInstructionsTimer =
			[NSTimer
			 scheduledTimerWithTimeInterval:0.5
			 target:self
			 selector:@selector(updateInstructionsTimer:)
			 userInfo:nil
			 repeats:YES];
	}
	
	if (!self.windowDidAppear)
	{
		self.windowDidAppear = YES;
		if (!sender)
		{
			[self readMemory:nil];
		}
	}
}

- (IBAction)showWindow:(id)sender
{
	[super showWindow:sender];
	
	[self windowDidShow:sender];
}

- (void)windowWillClose:(NSNotification *)notification
{
	[self.updateInstructionsTimer invalidate];
	self.updateInstructionsTimer = nil;
}

#pragma mark Disassembling

- (void)initializeDisassemblerObject:(ud_t *)object withBytes:(void *)bytes size:(ZGMemorySize)size
{
	ud_init(object);
	ud_set_input_buffer(object, bytes, size);
	ud_set_mode(object, self.currentProcess.pointerSize * 8);
	ud_set_syntax(object, UD_SYN_INTEL);
}

- (ZGInstruction *)findInstructionBeforeAddress:(ZGMemoryAddress)address inProcess:(ZGProcess *)process
{
	ZGInstruction *instruction = nil;
	
	for (ZGRegion *region in ZGRegionsForProcessTask(process.processTask))
	{
		if (address >= region.address && address < region.address + region.size)
		{
			// Start an arbitrary number of bytes before our address and decode the instructions
			// Eventually they will converge into correct offsets
			// So retrieve the offset and size to the last instruction while decoding
			// We do this instead of starting at region.address due to this leading to better performance
			
			ZGMemoryAddress startAddress = address - 1024;
			if (startAddress < region.address)
			{
				startAddress = region.address;
			}
			
			ZGMemorySize size = address - startAddress;
			
			void *bytes = NULL;
			if (ZGReadBytes(process.processTask, startAddress, &bytes, &size))
			{
				ud_t object;
				[self initializeDisassemblerObject:&object withBytes:bytes size:size];
				
				ZGMemoryAddress memoryOffset = 0;
				ZGMemorySize memorySize = 0;
				NSString *instructionText = nil;
				while (ud_disassemble(&object) > 0)
				{
					if (ud_insn_off(&object) + ud_insn_len(&object) >= size)
					{
						memoryOffset = ud_insn_off(&object);
						memorySize = ud_insn_len(&object);
						instructionText = @(ud_insn_asm(&object));
					}
				}
				
				instruction = [[ZGInstruction alloc] init];
				ZGVariable *variable = [[ZGVariable alloc] initWithValue:bytes + memoryOffset size:memorySize address:startAddress + memoryOffset type:ZGByteArray qualifier:0 pointerSize:process.pointerSize];
				[variable setShouldBeSearched:NO];
				instruction.variable = variable;
				instruction.text = instructionText;
				
				ZGFreeBytes(process.processTask, bytes, size);
			}
			
			break;
		}
	}
	
	return instruction;
}

- (void)updateInstructionsTimer:(NSTimer *)timer
{
	if (self.currentProcess.processID != NON_EXISTENT_PID_NUMBER && self.instructionsTableView.editedRow == -1 && !self.disassembling)
	{
		// Check to see if anything in the window needs to be updated
		NSRange visibleRowsRange = [self.instructionsTableView rowsInRect:self.instructionsTableView.visibleRect];
		if (visibleRowsRange.location + visibleRowsRange.length <= self.instructions.count)
		{
			__block BOOL needsToUpdateWindow = NO;
			[[self.instructions subarrayWithRange:visibleRowsRange] enumerateObjectsUsingBlock:^(ZGInstruction *instruction, NSUInteger index, BOOL *stop)
			 {
				 void *bytes = NULL;
				 ZGMemorySize size = instruction.variable.size;
				 if (ZGReadBytes(self.currentProcess.processTask, instruction.variable.address, &bytes, &size))
				 {
					 if (memcmp(bytes, instruction.variable.value, size) != 0)
					 {
						 needsToUpdateWindow = YES;
						 *stop = YES;
					 }
					 
					 ZGFreeBytes(self.currentProcess.processTask, bytes, size);
				 }
			 }];
			
			if (needsToUpdateWindow)
			{
				// Find a [start, end) range that we are allowed to remove from the table and insert in again with new instructions
				// Pick start and end such that they are aligned with the assembly instructions
				
				NSUInteger startRow = visibleRowsRange.location;
				
				do
				{
					if (startRow == 0) break;
					
					ZGInstruction *instruction = [self.instructions objectAtIndex:startRow];
					ZGInstruction *searchedInstruction = [self findInstructionBeforeAddress:instruction.variable.address inProcess:self.currentProcess];
					
					startRow--;
					
					if (searchedInstruction.variable.address + searchedInstruction.variable.size == instruction.variable.address)
					{
						break;
					}
				}
				while (YES);
				
				ZGInstruction *startInstruction = [self.instructions objectAtIndex:startRow];
				ZGMemoryAddress startAddress = startInstruction.variable.address;
				
				// Extend past first row if necessary
				if (startRow == 0)
				{
					ZGInstruction *searchedInstruction = [self findInstructionBeforeAddress:startInstruction.variable.address inProcess:self.currentProcess];
					if (searchedInstruction.variable.address + searchedInstruction.variable.size != startAddress)
					{
						startAddress = searchedInstruction.variable.address;
					}
				}
				
				NSUInteger endRow = visibleRowsRange.location + visibleRowsRange.length - 1;
				
				do
				{
					if (endRow >= self.instructions.count) break;
					
					ZGInstruction *instruction = [self.instructions objectAtIndex:endRow];
					ZGInstruction *searchedInstruction = [self findInstructionBeforeAddress:instruction.variable.address + instruction.variable.size inProcess:self.currentProcess];
					
					endRow++;
					
					if (searchedInstruction.variable.address == instruction.variable.address)
					{
						break;
					}
				}
				while (YES);
				
				ZGInstruction *endInstruction = [self.instructions objectAtIndex:endRow-1];
				ZGMemoryAddress endAddress = endInstruction.variable.address + endInstruction.variable.size;
				
				// Extend past last row if necessary
				if (endRow >= self.instructions.count)
				{
					ZGInstruction *searchedInstruction = [self findInstructionBeforeAddress:endInstruction.variable.address + endInstruction.variable.size inProcess:self.currentProcess];
					if (endInstruction.variable.address != searchedInstruction.variable.address)
					{
						endAddress = searchedInstruction.variable.address + searchedInstruction.variable.size;
					}
				}
				
				void *bytes = NULL;
				ZGMemorySize size = endAddress - startAddress;
				
				if (ZGReadBytes(self.currentProcess.processTask, startAddress, &bytes, &size))
				{
					ud_t object;
					[self initializeDisassemblerObject:&object withBytes:bytes size:size];
					
					NSMutableArray *instructionsToReplace = [[NSMutableArray alloc] init];
					
					while (ud_disassemble(&object) > 0)
					{
						ZGInstruction *newInstruction = [[ZGInstruction alloc] init];
						newInstruction.text = @(ud_insn_asm(&object));
						newInstruction.variable = [[ZGVariable alloc] initWithValue:bytes + ud_insn_off(&object) size:ud_insn_len(&object) address:startAddress + ud_insn_off(&object) type:ZGByteArray qualifier:0 pointerSize:self.currentProcess.pointerSize];
						
						[instructionsToReplace addObject:newInstruction];
					}
					
					// Replace the visible instructions
					NSMutableArray *newInstructions = [[NSMutableArray alloc] initWithArray:self.instructions];
					[newInstructions replaceObjectsInRange:NSMakeRange(startRow, endRow - startRow) withObjectsFromArray:instructionsToReplace];
					self.instructions = [NSArray arrayWithArray:newInstructions];
					
					[self.instructionsTableView reloadData];
					
					ZGFreeBytes(self.currentProcess.processTask, bytes, size);
				}
			}
		}
	}
}

- (IBAction)stopDisassembling:(id)sender
{
	self.disassembling = NO;
	[self.stopButton setEnabled:NO];
}

- (void)updateDisassemblerWithAddress:(ZGMemoryAddress)address size:(ZGMemorySize)theSize selectionAddress:(ZGMemoryAddress)selectionAddress
{
	[self.dissemblyProgressIndicator setMinValue:0];
	[self.dissemblyProgressIndicator setMaxValue:theSize];
	[self.dissemblyProgressIndicator setDoubleValue:0];
	[self.dissemblyProgressIndicator setHidden:NO];
	[self.addressTextField setEnabled:NO];
	[self.runningApplicationsPopUpButton setEnabled:NO];
	[self.stopButton setEnabled:YES];
	[self.stopButton setHidden:NO];
	
	self.instructions = @[];
	[self.instructionsTableView reloadData];
	
	self.currentMemoryAddress = address;
	self.currentMemorySize = 0;
	
	self.disassembling = YES;
	
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		void *bytes;
		ZGMemorySize size = theSize;
		if (ZGReadBytes(self.currentProcess.processTask, address, &bytes, &size))
		{
			ud_t object;
			[self initializeDisassemblerObject:&object withBytes:bytes size:size];
			
			__block NSMutableArray *newInstructions = [[NSMutableArray alloc] init];
			
			// We add instructions to table in batches. First time 1000 variables will be added, 2nd time 1000*2, third time 1000*2*2, etc.
			NSUInteger thresholdCount = 1000;
			
			NSUInteger totalInstructionCount = 0;
			
			// used for finding the instruction  theuser wants us to select
			__block NSUInteger selectionRow = 0;
			__block BOOL foundSelection = NO;
			
			// Block for adding a batch of instructions which will be used for later
			void (^addBatchOfInstructions)(void) = ^{
				NSArray *currentBatch = newInstructions;
				
				dispatch_async(dispatch_get_main_queue(), ^{
					NSMutableArray *appendedInstructions = [[NSMutableArray alloc] initWithArray:self.instructions];
					[appendedInstructions addObjectsFromArray:currentBatch];
					
					if (self.instructions.count == 0)
					{
						[self.window makeFirstResponder:self.instructionsTableView];
					}
					self.instructions = [NSArray arrayWithArray:appendedInstructions];
					[self.instructionsTableView noteNumberOfRowsChanged];
					self.currentMemorySize = self.instructions.count;
					
					if (foundSelection)
					{
						// Scroll such that the selected row is centered
						[self.instructionsTableView selectRowIndexes:[NSIndexSet indexSetWithIndex:selectionRow] byExtendingSelection:NO];
						NSRange visibleRowsRange = [self.instructionsTableView rowsInRect:self.instructionsTableView.visibleRect];
						[self.instructionsTableView scrollRowToVisible:MIN(selectionRow + visibleRowsRange.length / 2, self.instructions.count-1)];
						// we won't want to do this again
						foundSelection = NO;
					}
				});
			};
			
			while (ud_disassemble(&object) > 0)
			{
				ZGInstruction *instruction = [[ZGInstruction alloc] init];
				instruction.text = @(ud_insn_asm(&object));
				instruction.variable = [[ZGVariable alloc] initWithValue:bytes + ud_insn_off(&object) size:ud_insn_len(&object) address:address + ud_insn_off(&object) type:ZGByteArray qualifier:0 pointerSize:self.currentProcess.pointerSize];
				
				[newInstructions addObject:instruction];
				
				dispatch_async(dispatch_get_main_queue(), ^{
					self.dissemblyProgressIndicator.doubleValue += instruction.variable.size;
					if (selectionAddress >= instruction.variable.address && selectionAddress < instruction.variable.address + instruction.variable.size)
					{
						selectionRow = totalInstructionCount;
						foundSelection = YES;
					}
				});
				
				if (!self.disassembling)
				{
					break;
				}
				
				totalInstructionCount++;
				
				if (totalInstructionCount >= thresholdCount)
				{
					addBatchOfInstructions();
					newInstructions = [[NSMutableArray alloc] init];
					thresholdCount *= 2;
				}
			}
			
			// Add the leftover batch
			addBatchOfInstructions();
			
			dispatch_async(dispatch_get_main_queue(), ^{
				self.disassembling = NO;
				[self.dissemblyProgressIndicator setHidden:YES];
				[self.addressTextField setEnabled:YES];
				[self.runningApplicationsPopUpButton setEnabled:YES];
				[self.stopButton setHidden:YES];
			});
			
			ZGFreeBytes(self.currentProcess.processTask, bytes, size);
		}
	});
}

#pragma mark Handling Processes

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (object == [ZGProcessList sharedProcessList])
	{
		[self updateRunningProcesses];
	}
}

- (void)updateRunningProcesses
{
	[self.runningApplicationsPopUpButton removeAllItems];
	
	NSSortDescriptor *sortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"activationPolicy" ascending:YES];
	for (ZGRunningProcess *runningProcess in  [[[ZGProcessList sharedProcessList] runningProcesses] sortedArrayUsingDescriptors:@[sortDescriptor]])
	{
		if (runningProcess.processIdentifier != NSRunningApplication.currentApplication.processIdentifier)
		{
			NSMenuItem *menuItem = [[NSMenuItem alloc] init];
			menuItem.title = [NSString stringWithFormat:@"%@ (%d)", runningProcess.name, runningProcess.processIdentifier];
			NSImage *iconImage = [runningProcess.icon copy];
			iconImage.size = NSMakeSize(16, 16);
			menuItem.image = iconImage;
			ZGProcess *representedProcess =
				[[ZGProcess alloc]
				 initWithName:runningProcess.name
				 processID:runningProcess.processIdentifier
				 set64Bit:runningProcess.is64Bit];
			
			menuItem.representedObject = representedProcess;
			
			[self.runningApplicationsPopUpButton.menu addItem:menuItem];
			
			if (self.currentProcess.processID == runningProcess.processIdentifier || [self.desiredProcessName isEqualToString:runningProcess.name])
			{
				[self.runningApplicationsPopUpButton selectItem:self.runningApplicationsPopUpButton.lastItem];
			}
		}
	}
	
	// Handle dead process
	if (self.desiredProcessName && ![self.desiredProcessName isEqualToString:[self.runningApplicationsPopUpButton.selectedItem.representedObject name]])
	{
		NSMenuItem *menuItem = [[NSMenuItem alloc] init];
		menuItem.title = [NSString stringWithFormat:@"%@ (none)", self.desiredProcessName];
		NSImage *iconImage = [[NSImage imageNamed:@"NSDefaultApplicationIcon"] copy];
		iconImage.size = NSMakeSize(16, 16);
		menuItem.image = iconImage;
		menuItem.representedObject = [[ZGProcess alloc] initWithName:self.desiredProcessName processID:NON_EXISTENT_PID_NUMBER set64Bit:YES];
		[self.runningApplicationsPopUpButton.menu addItem:menuItem];
		[self.runningApplicationsPopUpButton selectItem:self.runningApplicationsPopUpButton.lastItem];
	}
	
	self.currentProcess = self.runningApplicationsPopUpButton.selectedItem.representedObject;
}

- (void)switchProcessMenuItemAndSelectAddress:(ZGMemoryAddress)address
{
	if ([self.runningApplicationsPopUpButton.selectedItem.representedObject processID] != self.currentProcess.processID)
	{
		self.addressTextField.stringValue = [NSString stringWithFormat:@"0x%llX", address];
		self.desiredProcessName = [self.runningApplicationsPopUpButton.selectedItem.representedObject name];
		self.currentProcess = self.runningApplicationsPopUpButton.selectedItem.representedObject;
	}
}

- (IBAction)runningApplicationsPopUpButton:(id)sender
{
	[self switchProcessMenuItemAndSelectAddress:0x0];
}

#pragma mark Changing disassembler view

- (IBAction)readMemory:(id)sender
{
	BOOL success = NO;
	
	if (self.currentProcess.processID == NON_EXISTENT_PID_NUMBER || ![self.currentProcess hasGrantedAccess])
	{
		goto END_DEBUGGER_CHANGE;
	}
	
	// create scope block to allow for goto
	{
		NSString *calculatedMemoryAddressExpression = [ZGCalculator evaluateExpression:self.addressTextField.stringValue];
		
		ZGMemoryAddress calculatedMemoryAddress = 0;
		
		if (isValidNumber(calculatedMemoryAddressExpression))
		{
			calculatedMemoryAddress = memoryAddressFromExpression(calculatedMemoryAddressExpression);
		}
		
		NSArray *memoryRegions = ZGRegionsForProcessTask(self.currentProcess.processTask);
		if (memoryRegions.count == 0)
		{
			goto END_DEBUGGER_CHANGE;
		}
		
		ZGRegion *chosenRegion = nil;
		for (ZGRegion *region in memoryRegions)
		{
			if ((region.protection & VM_PROT_READ && region.protection & VM_PROT_EXECUTE) && (calculatedMemoryAddress <= 0 || (calculatedMemoryAddress >= region.address && calculatedMemoryAddress < region.address + region.size)))
			{
				chosenRegion = region;
				break;
			}
		}
		
		if (!chosenRegion)
		{
			goto END_DEBUGGER_CHANGE;
		}
		
		if (calculatedMemoryAddress <= 0)
		{
			calculatedMemoryAddress = chosenRegion.address;
			[self.addressTextField setStringValue:[NSString stringWithFormat:@"0x%llX", calculatedMemoryAddress]];
		}
		
		// Dissemble within a range from +- WINDOW_SIZE from selection address
		const NSUInteger WINDOW_SIZE = 50000;
		
		ZGMemoryAddress lowBoundAddress = calculatedMemoryAddress - WINDOW_SIZE;
		if (lowBoundAddress <= chosenRegion.address)
		{
			lowBoundAddress = chosenRegion.address;
		}
		else
		{
			lowBoundAddress = [self findInstructionBeforeAddress:lowBoundAddress inProcess:self.currentProcess].variable.address;
			if (lowBoundAddress < chosenRegion.address)
			{
				lowBoundAddress = chosenRegion.address;
			}
		}
		
		ZGMemoryAddress highBoundAddress = calculatedMemoryAddress + WINDOW_SIZE;
		if (highBoundAddress >= chosenRegion.address + chosenRegion.size)
		{
			highBoundAddress = chosenRegion.address + chosenRegion.size;
		}
		else
		{
			highBoundAddress = [self findInstructionBeforeAddress:highBoundAddress inProcess:self.currentProcess].variable.address;
			if (highBoundAddress <= chosenRegion.address || highBoundAddress > chosenRegion.address + chosenRegion.size)
			{
				highBoundAddress = chosenRegion.address + chosenRegion.size;
			}
		}
		
		[self.undoManager removeAllActions];
		[self updateDisassemblerWithAddress:lowBoundAddress size:highBoundAddress - lowBoundAddress selectionAddress:calculatedMemoryAddress];
		
		success = YES;
	}
	
END_DEBUGGER_CHANGE:
	if (!success)
	{
		// clear data
		self.instructions = [NSArray array];
		[self.instructionsTableView reloadData];
	}
}

#pragma mark Useful methods for the world

- (ZGInstruction *)selectedInstruction
{
	ZGInstruction *instruction = nil;
	
	if (self.instructionsTableView.selectedRow >= 0 && (NSUInteger)self.instructionsTableView.selectedRow < self.instructions.count)
	{
		instruction = [self.instructions objectAtIndex:self.instructionsTableView.selectedRow];
	}
	
	return instruction;
}

- (void)jumpToMemoryAddress:(ZGMemoryAddress)address inProcess:(ZGProcess *)requestedProcess
{	
	NSMenuItem *targetMenuItem = nil;
	for (NSMenuItem *menuItem in self.runningApplicationsPopUpButton.menu.itemArray)
	{
		ZGProcess *process = menuItem.representedObject;
		if ([process processID] == requestedProcess.processID)
		{
			targetMenuItem = menuItem;
			break;
		}
	}
	
	if (targetMenuItem)
	{
		self.addressTextField.stringValue = [NSString stringWithFormat:@"0x%llX", address];
		
		if ([targetMenuItem.representedObject processID] != self.currentProcess.processID)
		{
			[self.runningApplicationsPopUpButton selectItem:targetMenuItem];
			[self switchProcessMenuItemAndSelectAddress:address];
			self.instructions = @[];
			[self.instructionsTableView reloadData];
		}
		else
		{
			[self readMemory:nil];
		}
	}
	else
	{
		NSLog(@"Could not find target process!");
	}
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem
{
	if (menuItem.action == @selector(nopVariables:))
	{
		[menuItem setTitle:[NSString stringWithFormat:@"NOP Instruction%@", self.instructionsTableView.selectedRowIndexes.count == 1 ? @"" : @"s"]];
		if (self.instructionsTableView.selectedRowIndexes.count <= 0 || self.currentProcess.processID == NON_EXISTENT_PID_NUMBER || self.instructionsTableView.editedRow != -1)
		{
			return NO;
		}
	}
	else if (menuItem.action == @selector(copy:))
	{
		if (self.instructionsTableView.selectedRowIndexes.count <= 0)
		{
			return NO;
		}
	}
	
	return YES;
}

- (NSUndoManager *)windowWillReturnUndoManager:(id)sender
{
	return self.undoManager;
}

- (IBAction)copy:(id)sender
{
	NSMutableArray *descriptionComponents = [[NSMutableArray alloc] init];
	NSArray *instructions = [self.instructions objectsAtIndexes:[self.instructionsTableView selectedRowIndexes]];
	for (ZGInstruction *instruction in instructions)
	{
		[descriptionComponents addObject:[@[instruction.variable.addressStringValue, instruction.text, instruction.variable.stringValue] componentsJoinedByString:@"\t"]];
	}
	
	[[NSPasteboard generalPasteboard] declareTypes:@[NSStringPboardType] owner:self];
	[[NSPasteboard generalPasteboard] setString:[descriptionComponents componentsJoinedByString:@"\n"] forType:NSStringPboardType];
}

#pragma mark TableView Methods

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView
{
	return self.instructions.count;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	id result = nil;
	if (rowIndex >= 0 && (NSUInteger)rowIndex < self.instructions.count)
	{
		ZGInstruction *instruction = [self.instructions objectAtIndex:rowIndex];
		if ([tableColumn.identifier isEqualToString:@"address"])
		{
			result = instruction.variable.addressStringValue;
		}
		else if ([tableColumn.identifier isEqualToString:@"instruction"])
		{
			result = instruction.text;
		}
		else if ([tableColumn.identifier isEqualToString:@"bytes"])
		{
			result = instruction.variable.stringValue;
		}
	}
	
	return result;
}

- (void)tableView:(NSTableView *)tableView setObjectValue:(id)object forTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)rowIndex
{
	if ([tableColumn.identifier isEqualToString:@"bytes"] && rowIndex >= 0 && (NSUInteger)rowIndex < self.instructions.count)
	{
		ZGInstruction *instruction = [self.instructions objectAtIndex:rowIndex];
		[self replaceInstructions:@[instruction] fromOldStringValues:@[instruction.variable.stringValue] toNewStringValues:@[object] actionName:@"Instruction Change"];
	}
}

#pragma mark Modifying instructions

- (void)replaceInstructions:(NSArray *)instructions fromOldStringValues:(NSArray *)oldStringValues toNewStringValues:(NSArray *)newStringValues actionName:(NSString *)actionName
{
	for (NSUInteger index = 0; index < instructions.count; index++)
	{
		ZGInstruction *instruction = [instructions objectAtIndex:index];
		[self writeStringValue:[newStringValues objectAtIndex:index] atAddress:instruction.variable.address];
	}
	
	[self.undoManager setActionName:[actionName stringByAppendingFormat:@"%@", instructions.count == 1 ? @"" : @"s"]];
	
	[[self.undoManager prepareWithInvocationTarget:self] replaceInstructions:instructions fromOldStringValues:newStringValues toNewStringValues:oldStringValues actionName:actionName];
}

- (void)writeStringValue:(NSString *)stringValue atAddress:(ZGMemoryAddress)address
{
	ZGMemorySize newSize = 0;
	void *newValue = valueFromString(self.currentProcess, stringValue, ZGByteArray, &newSize);
	
	if (newValue)
	{
		ZGMemoryAddress protectionAddress = address;
		ZGMemorySize protectionSize = newSize;
		ZGMemoryProtection oldProtection = 0;
		
		if (ZGMemoryProtectionInRegion(self.currentProcess.processTask, &protectionAddress, &protectionSize, &oldProtection))
		{
			BOOL canWrite = oldProtection & VM_PROT_WRITE;
			if (!canWrite)
			{
				canWrite = ZGProtect(self.currentProcess.processTask, protectionAddress, protectionSize, oldProtection | VM_PROT_WRITE);
			}
			
			if (canWrite)
			{
				ZGWriteBytes(self.currentProcess.processTask, address, newValue, newSize);
				
				// Re-protect the region back to the way it was
				if (!(oldProtection & VM_PROT_WRITE))
				{
					ZGProtect(self.currentProcess.processTask, protectionAddress, protectionSize, oldProtection);
				}
			}
		}
		
		free(newValue);
	}
}

- (IBAction)nopVariables:(id)sender
{
	NSArray *selectedInstructions = [self.instructions objectsAtIndexes:[self.instructionsTableView selectedRowIndexes]];
	NSMutableArray *newStringValues = [[NSMutableArray alloc] init];
	NSMutableArray *oldStringValues = [[NSMutableArray alloc] init];
	
	for (NSUInteger instructionIndex = 0; instructionIndex < selectedInstructions.count; instructionIndex++)
	{
		ZGInstruction *instruction = [selectedInstructions objectAtIndex:instructionIndex];
		[oldStringValues addObject:instruction.variable.stringValue];
		
		NSMutableArray *nopComponents = [[NSMutableArray alloc] init];
		for (NSUInteger nopIndex = 0; nopIndex < instruction.variable.size; nopIndex++)
		{
			[nopComponents addObject:@"90"];
		}
		
		[newStringValues addObject:[nopComponents componentsJoinedByString:@" "]];
	}
	
	[self replaceInstructions:selectedInstructions fromOldStringValues:oldStringValues toNewStringValues:newStringValues actionName:@"NOP Change"];
}

@end