/**
 * @format
 */

import React from 'react';
import renderer, {act} from 'react-test-renderer';
import {Text, TouchableOpacity} from 'react-native';
import {Button} from '../src/components/Button';

describe('Button', () => {
  it('renders the provided title', () => {
    const tree = renderer.create(<Button title="Join" onPress={() => {}} />);
    const label = tree.root.findByType(Text);
    expect(label.props.children).toBe('Join');
  });

  it('calls onPress when pressed', () => {
    const onPress = jest.fn();
    const tree = renderer.create(<Button title="Join" onPress={onPress} />);
    act(() => {
      tree.root.findByType(TouchableOpacity).props.onPress();
    });
    expect(onPress).toHaveBeenCalledTimes(1);
  });
});
