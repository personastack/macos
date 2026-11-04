#!/usr/bin/env python3
"""Configure the synthesized main installer for Apple Silicon Macs."""

import sys, xml.etree.ElementTree as ET
path = sys.argv[1]
root = ET.parse(path).getroot()
title = root.find('title')
if title is None:
    title = ET.SubElement(root, 'title')
title.text = 'PersonaStack'
options = root.find('options')
if options is None:
    options = ET.SubElement(root, 'options')
options.set('customize', 'never')
options.set('hostArchitectures', 'arm64')
domains = ET.SubElement(root, 'domains')
domains.set('enable_anywhere', 'false')
domains.set('enable_currentUserHome', 'false')
domains.set('enable_localSystem', 'true')
volume = ET.SubElement(root, 'volume-check')
ET.SubElement(volume, 'allowed-os-versions').append(ET.Element('os-version', min='14.0'))
close = ET.SubElement(ET.SubElement(root, 'pkg-ref', id='ai.personastack.desktop'), 'must-close')
ET.SubElement(close, 'app', id='ai.personastack.desktop')
ET.ElementTree(root).write(path, encoding='utf-8', xml_declaration=True)
